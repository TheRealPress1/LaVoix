import AppKit
import Combine
import Foundation

/// Look, from the keyboard: hold Fn (dictation starts as it always does), add Control, say what you want while you point or circle, let go.
/// The same recording becomes the Look: its words are not typed anywhere and not saved to the dictation history, they go to myOS together
/// with what was on the screen when Control went down and the box you circled.
///
/// How it stays out of the way of dictation:
/// - It only listens (global monitors that cannot change or swallow a key) and never touches the hotkey manager.
/// - It is off until myOS switches it on (`look.configure`), and the choice is kept.
/// - It begins only while a plain dictation is being recorded by Fn held down, and never while a meeting is recording.
/// - The only change to dictation is one route: when the hotkey stop asks `consumeRouteForStop`, a pending Look answers yes once, and the
///   stop path hands the spoken words to `finish` instead of typing them. A pending Look that nobody consumed (dictation cancelled, Fn
///   released and nothing stopped) expires two seconds after Fn is released, so it can never swallow a later, ordinary dictation.
@MainActor
final class LookSession {
    static let shared = LookSession()
    private static let enabledKey = "LookChordEnabled"
    /// How long after Fn is released a pending Look may still claim the stop.
    private static let graceAfterRelease: TimeInterval = 2

    private(set) var enabled = UserDefaults.standard.bool(forKey: LookSession.enabledKey)
    var persists = true

    private var isDictating: () -> Bool = { false }
    private var levels: AnyPublisher<CGFloat, Never>?
    private var levelSubscription: AnyCancellable?
    private var flagsMonitors: [Any] = []
    private var mouseMonitors: [Any] = []
    private var chordWasDown = false
    private var sessionID = 0
    private var sessionActive = false
    private var pending = false
    private var pendingDeadline: Date?
    private var path: [CGPoint] = []
    private var read: Task<EngineLookRead?, Never>?
    private var taken: (path: [CGPoint], read: Task<EngineLookRead?, Never>?)?

    /// Called once by the dictation screen: how to tell that a plain dictation is being recorded right now, and the microphone level the
    /// cursor companion's waveform follows while it is.
    func install(isDictating: @escaping () -> Bool, levels: AnyPublisher<CGFloat, Never>? = nil) {
        self.isDictating = isDictating
        self.levels = levels
        if self.enabled { self.startObserving() }
    }

    func setEnabled(_ on: Bool) {
        guard on != self.enabled else { return }
        self.enabled = on
        if self.persists { UserDefaults.standard.set(on, forKey: Self.enabledKey) }
        if on { self.startObserving() } else { self.stopObserving() }
    }

    var statusText: [String: Any] { ["enabled": self.enabled, "chord": "fn+control", "active": self.sessionActive, "pending": self.pending] }

    // MARK: Watching the modifier keys

    private func startObserving() {
        guard self.flagsMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in self?.flagsChanged(flags) }
        }) { self.flagsMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in self?.flagsChanged(flags) }
            return event
        }) { self.flagsMonitors.append(local) }
    }

    private func stopObserving() {
        for monitor in self.flagsMonitors + self.mouseMonitors { NSEvent.removeMonitor(monitor) }
        self.flagsMonitors = []
        self.mouseMonitors = []
        self.reset()
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let chord = LookChord.isChord(flags)
        if !flags.contains(.function), self.sessionActive {
            // Fn is up: the dictation stops now and claims the route within milliseconds; if nothing does, this session ends.
            if self.pendingDeadline == nil { self.pendingDeadline = Date().addingTimeInterval(Self.graceAfterRelease) }
            let mine = self.sessionID
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((Self.graceAfterRelease + 0.5) * 1_000_000_000))
                if let self, self.sessionID == mine, self.sessionActive { self.reset() }
            }
        }
        if chord, !self.chordWasDown { self.begin() }
        self.chordWasDown = chord
    }

    // MARK: A session

    private func begin() {
        guard self.enabled, !self.sessionActive, self.isDictating() else { return }
        self.sessionID += 1
        let mine = self.sessionID
        self.sessionActive = true
        self.pending = false
        self.pendingDeadline = nil
        self.path = CGEvent(source: nil).map { [$0.location] } ?? []
        // Never during a meeting recording (the same rule as the look.capture op), and if that cannot be told in time, not at all.
        self.read = Task { @MainActor [weak self] in
            let snapshot = await EngineTimeout.run(seconds: 3, { await LiveEngineActivity().snapshot() })
            guard let self, self.sessionID == mine, self.sessionActive else { return nil }
            guard let snapshot, snapshot["recording"] as? Bool != true else {
                DebugLogger.shared.info("Look: not started (a meeting is recording or the engine could not say)", source: "LookSession")
                self.reset()
                return nil
            }
            self.pending = true
            self.startTrackingPointer()
            // The cursor companion appears at the pointer as a waveform that moves with the voice; it never draws during a meeting recording
            // because this point is not reached then.
            LookBuddy.shared.begin(.listening)
            if let start = self.path.first { LookBuddy.shared.addTrail(quartz: start) }
            self.levelSubscription = self.levels?.receive(on: DispatchQueue.main).sink { level in MainActor.assumeIsolated { LookBuddy.shared.setLevel(level) } }
            DebugLogger.shared.info("Look: started", source: "LookSession")
            return await LiveEngineLook().read(app: nil, scope: "window")
        }
    }

    private func startTrackingPointer() {
        guard self.mouseMonitors.isEmpty else { return }
        let moved: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.samplePointer() } }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], handler: moved) { self.mouseMonitors.append(monitor) }
    }

    private func stopTrackingPointer() {
        for monitor in self.mouseMonitors { NSEvent.removeMonitor(monitor) }
        self.mouseMonitors = []
    }

    private func samplePointer() {
        guard self.sessionActive, let here = CGEvent(source: nil)?.location else { return }
        if let last = self.path.last, hypot(here.x - last.x, here.y - last.y) < 4 { return }
        if self.path.count < 3000 {
            self.path.append(here)
            LookBuddy.shared.addTrail(quartz: here)
        }
    }

    /// Asked by the hotkey stop: is this stop a Look? Answers yes once for a pending Look, and keeps what was gathered for `finish`.
    func consumeRouteForStop() -> Bool {
        guard self.sessionActive, self.pending else { return false }
        if let deadline = self.pendingDeadline, Date() > deadline {
            self.reset()
            return false
        }
        self.stopTrackingPointer()
        // The words are in: the companion turns into a spinner until myOS has answered (it lets it go), or twenty seconds have passed.
        self.levelSubscription = nil
        LookBuddy.shared.finishTrail(region: LookPath.region(from: self.path))
        LookBuddy.shared.setMode(.thinking)
        let finishedSession = self.sessionID
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if let self, self.sessionID == finishedSession, !self.sessionActive { LookBuddy.shared.end() }
        }
        self.taken = (self.path, self.read)
        self.sessionActive = false
        self.pending = false
        self.pendingDeadline = nil
        self.read = nil
        self.path = []
        return true
    }

    /// The spoken words have arrived: read the circled part of the picture taken when Control went down and hand everything to myOS.
    func finish(said: String) async {
        guard let taken = self.taken else { LookBuddy.shared.end(); return }
        self.taken = nil
        let region = LookPath.region(from: taken.path)
        guard let read = await taken.read?.value else { LookBuddy.shared.end(); return }
        let capture = await LiveEngineLook().finish(read, region: region, save: false)
        var event: [String: Any] = ["kind": "captured", "said": String(said.prefix(1000)), "path_points": taken.path.count, "capture": capture]
        if let region { event["region"] = ["x": region.minX, "y": region.minY, "w": region.width, "h": region.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { LookBuddy.shared.end(); return }
        await LookEvents.shared.push(json)
        DebugLogger.shared.info("Look: captured (said \(said.count) chars, \(taken.path.count) pointer points, region \(region != nil), ocr \((capture["ocr_text"] as? String)?.count ?? 0) chars)", source: "LookSession")
    }

    private func reset() {
        self.stopTrackingPointer()
        self.levelSubscription = nil
        LookBuddy.shared.end()
        self.sessionActive = false
        self.pending = false
        self.pendingDeadline = nil
        self.path = []
        self.read?.cancel()
        self.read = nil
    }
}

/// The two modifier keys of the chord: Fn and Control, and nothing else held.
nonisolated enum LookChord {
    static func isChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .shift, .control, .function]) == [.control, .function]
    }
}

/// What the pointer did while the chord was held: a box around it when it went far enough to mean "this part", else nothing.
nonisolated enum LookPath {
    static let minLength: CGFloat = 150
    static let minSpan: CGFloat = 40
    static let padding: CGFloat = 20
    static let minSide: CGFloat = 60

    /// The padded bounding box of the path, or nil when the pointer barely moved (then the whole window is meant).
    static func region(from points: [CGPoint]) -> CGRect? {
        guard points.count >= 2 else { return nil }
        var length: CGFloat = 0
        var minX = points[0].x, maxX = points[0].x, minY = points[0].y, maxY = points[0].y
        for (a, b) in zip(points, points.dropFirst()) {
            length += hypot(b.x - a.x, b.y - a.y)
            minX = min(minX, b.x); maxX = max(maxX, b.x); minY = min(minY, b.y); maxY = max(maxY, b.y)
        }
        guard length >= self.minLength, max(maxX - minX, maxY - minY) >= self.minSpan else { return nil }
        var box = CGRect(x: minX - self.padding, y: minY - self.padding, width: (maxX - minX) + 2 * self.padding, height: (maxY - minY) + 2 * self.padding)
        if box.width < self.minSide { box = box.insetBy(dx: -(self.minSide - box.width) / 2, dy: 0) }
        if box.height < self.minSide { box = box.insetBy(dx: 0, dy: -(self.minSide - box.height) / 2) }
        return box
    }
}

/// What the engine tells myOS about Look, one event at a time (JSON text), for the `look.wait` long poll.
actor LookEvents {
    static let shared = LookEvents()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var token = 0

    func push(_ json: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: json)
        } else {
            self.queue.append(json)
            if self.queue.count > 5 { self.queue.removeFirst() }
        }
    }

    /// The next event, or nil after `timeout` seconds.
    func next(timeout: TimeInterval) async -> String? {
        if !self.queue.isEmpty { return self.queue.removeFirst() }
        if let old = self.waiter {
            self.waiter = nil
            old.resume(returning: nil)
        }
        self.token += 1
        let mine = self.token
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(mine)
            }
        }
    }

    private func expire(_ mine: Int) {
        guard mine == self.token, let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

/// The switch for the chord and its state, for myOS.
nonisolated protocol EngineLookControlProviding: Sendable {
    func setEnabled(_ on: Bool) async
    func status() async -> [String: Any]
}

nonisolated struct LiveEngineLookControl: EngineLookControlProviding {
    func setEnabled(_ on: Bool) async { await MainActor.run { LookSession.shared.setEnabled(on) } }
    func status() async -> [String: Any] { await MainActor.run { LookSession.shared.statusText } }
}
