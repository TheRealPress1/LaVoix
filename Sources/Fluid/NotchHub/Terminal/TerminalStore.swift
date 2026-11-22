import AppKit
import Combine
import Foundation

// The notch terminal (docs/21-notch-terminal.md in the myos repo): a command runner for the small things (aws, supabase, vercel, git), not an agent window and not a
// full terminal. It exists only for him: nothing outside the notch's own keyboard can open it, type in it or read it. The rules, in code:
//  - it is locked until Touch ID (biometrics only) says yes, and locks again when the notch has been closed two minutes, at screen lock and at sleep;
//  - typing counts only if it came from the keyboard hardware (see TerminalGuard and TerminalInputTextView);
//  - there is no engine socket operation, URL, AppleScript command or myOS call for it, and no assistant or model can reach it (an autotest scans the sources);
//  - nothing is logged but "a session started or ended"; commands and output are never written anywhere, never sent anywhere;
//  - the notch is kept out of screenshots while the terminal is open and unlocked.

enum NotchTerminalSettings {
    private static let enabledKey = "LaVoixNotchTerminalEnabled"
    private static let folderKey = "LaVoixNotchTerminalStartFolder"

    /// Off until he turns it on. Turning it on only makes the tab appear; Touch ID still opens it.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    /// Where a new session starts: the home folder, unless a folder that exists is set.
    static var startDirectory: String {
        var isDirectory: ObjCBool = false
        if let set = UserDefaults.standard.string(forKey: self.folderKey), FileManager.default.fileExists(atPath: set, isDirectory: &isDirectory), isDirectory.boolValue { return set }
        return NSHomeDirectory()
    }
}

@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore(authenticator: TouchIDAuthenticator())

    enum SessionState: Equatable {
        case none
        case running
        case ended(Int32)
        case failed(String)
    }

    @Published private(set) var isUnlocked = false
    @Published private(set) var isUnlocking = false
    @Published private(set) var rendered: [RenderedLine] = []
    /// Counts every redraw, so the view can scroll to the newest line.
    @Published private(set) var scrollTick = 0
    @Published private(set) var isBusy = false
    @Published private(set) var canForceStop = false
    @Published private(set) var sessionState = SessionState.none
    /// A full-screen program (vim, htop) started: this tab cannot draw it.
    @Published private(set) var needsFullTerminal = false
    @Published var notice: String?

    nonisolated let buffer = TerminalBuffer()
    private let authenticator: TerminalAuthenticating
    private let startsSessions: Bool
    private var session: TerminalSession?
    private var sessionToken = UUID()
    private var cache: [Int: RenderedLine] = [:]
    private var lastRevision = -1
    private var flushTimer: Timer?
    private var lockTimer: Timer?
    private var closedAt: Date?
    private var history: [String] = []
    private var historyIndex: Int?
    private var draft = ""
    private var columns = 100
    private var rows = 14
    private var attached = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private(set) var blockedKeyCount = 0
    /// For tests only: lets a test point the session at a throwaway folder and a shell without start-up files.
    var configAdjuster: ((TerminalSession.Config) -> TerminalSession.Config)?

    init(authenticator: TerminalAuthenticating, startsSessions: Bool = true) {
        self.authenticator = authenticator
        self.startsSessions = startsSessions
    }

    // MARK: - wiring to the notch

    /// Called once when the notch starts: watches whether the notch is open and which tab is showing, and keeps the notch out of screenshots while the terminal is open.
    func attach(to controller: NotchHubController) {
        guard !self.attached else { return }
        self.attached = true
        controller.model.$isOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self else { return }
                if open { self.closedAt = nil } else if self.closedAt == nil { self.closedAt = Date() }
            }
            .store(in: &self.cancellables)
        Publishers.CombineLatest(self.$isUnlocked, controller.model.$selectedWidgetID)
            .receive(on: RunLoop.main)
            .sink { [weak controller] unlocked, tab in controller?.setCaptureHidden(unlocked && tab == "terminal") }
            .store(in: &self.cancellables)
        self.lockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isUnlocked, let closed = self.closedAt, TerminalGuard.shouldAutoLock(closedFor: Date().timeIntervalSince(closed)) else { return }
                self.lock()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            self.observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.lock() } })
        }
        self.observers.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        })
    }

    // MARK: - lock

    /// Asks for his fingerprint. Nothing else opens the terminal.
    func unlock() async {
        guard !self.isUnlocked, !self.isUnlocking else { return }
        self.isUnlocking = true
        self.notice = nil
        let result = await self.authenticator.authenticate(reason: "Open the terminal in the notch")
        self.isUnlocking = false
        switch result {
        case .success:
            self.isUnlocked = true
            self.closedAt = nil
            if self.startsSessions, self.sessionState == .none { self.startSession() }
            self.startFlushing()
            self.flush(force: true)
        case .cancelled:
            break
        case let .failed(message), let .unavailable(message):
            self.notice = message
        }
    }

    /// Locks the view: the scrollback is cleared from what is drawn. A running command keeps running.
    func lock() {
        guard self.isUnlocked else { return }
        self.isUnlocked = false
        self.stopFlushing()
        self.rendered = []
        self.cache = [:]
        self.historyIndex = nil
        self.notice = nil
    }

    // MARK: - session

    private func startSession() {
        guard TerminalSession.canStartSafely else {
            self.sessionState = .failed(TerminalSession.StartError.disclaimUnavailable.localizedDescription)
            return
        }
        self.session?.terminate()
        self.buffer.reset()
        self.cache = [:]
        self.rendered = []
        self.lastRevision = -1
        self.isBusy = false
        self.canForceStop = false
        self.needsFullTerminal = false
        let shell = TerminalGuard.loginShell()
        var config = TerminalSession.Config(
            shell: shell,
            directory: NotchTerminalSettings.startDirectory,
            environment: TerminalGuard.environment(shell: shell, home: NSHomeDirectory(), user: NSUserName(), parent: ProcessInfo.processInfo.environment),
            columns: self.columns,
            rows: self.rows
        )
        if let adjust = self.configAdjuster { config = adjust(config) }
        let token = UUID()
        self.sessionToken = token
        let buffer = self.buffer
        do {
            self.session = try TerminalSession.start(
                config,
                onOutput: { data in buffer.feed(data) },
                onBusyChanged: { [weak self] busy in Task { @MainActor in self?.busyChanged(busy, token: token) } },
                onExit: { [weak self] code in Task { @MainActor in self?.sessionEnded(code, token: token) } }
            )
            self.sessionState = .running
            DebugLogger.shared.info("Terminal: a session started", source: "Terminal")
        } catch {
            self.session = nil
            self.sessionState = .failed(error.localizedDescription)
            DebugLogger.shared.warning("Terminal: a session could not start", source: "Terminal")
        }
    }

    private func busyChanged(_ busy: Bool, token: UUID) {
        guard token == self.sessionToken else { return }
        self.isBusy = busy
        self.canForceStop = false
        guard busy else { return }
        // A command that ignores Ctrl-C gets a stronger button after three seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, token == self.sessionToken, self.isBusy else { return }
            self.canForceStop = true
        }
    }

    private func sessionEnded(_ code: Int32, token: UUID) {
        guard token == self.sessionToken else { return }
        self.session = nil
        self.isBusy = false
        self.canForceStop = false
        self.sessionState = .ended(code)
        self.flush(force: true)
        DebugLogger.shared.info("Terminal: a session ended (exit \(code))", source: "Terminal")
    }

    func newSession() {
        guard self.isUnlocked else { return }
        self.sessionState = .none
        self.startSession()
        self.startFlushing()
    }

    /// Ends everything: used when the terminal is switched off and when the engine quits.
    func shutdown() {
        self.session?.terminate()
        self.session = nil
        self.sessionToken = UUID()
        self.sessionState = .none
        self.isBusy = false
        self.canForceStop = false
        self.history = []
        self.historyIndex = nil
        self.lock()
        self.buffer.reset()
        self.rendered = []
    }

    // MARK: - what the person does (every entry point here is called by the keyboard-gated text field or a button in the tab)

    /// Runs what he typed. Returns false when it was refused (the text stays in the field).
    @discardableResult
    func submit(_ raw: String) -> Bool {
        guard self.isUnlocked else { return false }
        let line = TerminalGuard.sanitized(raw)
        if TerminalGuard.refusesPasswordCommand(line) {
            self.notice = "sudo and su ask for a password, and there is no safe place to type one here. Use the Terminal app for those."
            return false
        }
        self.notice = nil
        if self.sessionState != .running { self.sessionState = .none; self.startSession() }
        guard self.sessionState == .running, let session = self.session else { return false }
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, self.history.last != line {
            self.history.append(line)
            if self.history.count > 200 { self.history.removeFirst() }
        }
        self.historyIndex = nil
        session.send(TerminalGuard.wire(for: line))
        return true
    }

    /// Ctrl-C. Returns true when a command was running and got the interrupt.
    @discardableResult
    func interrupt() -> Bool {
        guard self.isUnlocked, self.isBusy, let session = self.session else { return false }
        session.interrupt()
        return true
    }

    func forceStop() {
        guard self.isUnlocked, self.isBusy else { return }
        self.session?.forceStopForeground()
    }

    func historyPrevious(current: String) -> String? {
        guard !self.history.isEmpty else { return nil }
        if self.historyIndex == nil { self.draft = current; self.historyIndex = self.history.count }
        guard let index = self.historyIndex, index > 0 else { return nil }
        self.historyIndex = index - 1
        return self.history[index - 1]
    }

    func historyNext() -> String? {
        guard let index = self.historyIndex else { return nil }
        if index + 1 < self.history.count { self.historyIndex = index + 1; return self.history[index + 1] }
        self.historyIndex = nil
        return self.draft
    }

    /// A key or paste that did not come from the keyboard hardware was dropped. Counted, never recorded.
    func noteBlockedInput() {
        self.blockedKeyCount += 1
        self.notice = "A key that did not come from the keyboard was ignored."
    }

    /// A paste had line breaks joined: say so, and how to paste it as copied.
    func noteJoinedPaste(lines: Int) {
        self.notice = "\(lines + 1) lines joined into one command. Shift-Command-V pastes them as they were copied."
    }

    /// The tab's width in columns, so programs wrap where the tab does.
    func setSize(width: CGFloat) {
        let columns = max(40, Int(width / 7.3))
        guard abs(columns - self.columns) >= 2 else { return }
        self.columns = columns
        self.session?.resize(columns: columns, rows: self.rows)
    }

    // MARK: - drawing

    private func startFlushing() {
        guard self.flushTimer == nil else { return }
        self.flushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush(force: false) }
        }
    }

    private func stopFlushing() {
        self.flushTimer?.invalidate()
        self.flushTimer = nil
    }

    func flush(force: Bool) {
        guard self.isUnlocked else { return }
        let snapshot = self.buffer.snapshot()
        guard force || snapshot.revision != self.lastRevision else { return }
        self.lastRevision = snapshot.revision
        if self.needsFullTerminal != snapshot.alternateScreen { self.needsFullTerminal = snapshot.alternateScreen }
        var out: [RenderedLine] = []
        out.reserveCapacity(snapshot.lines.count + 1)
        var used = Set<Int>()
        for line in snapshot.lines {
            used.insert(line.id)
            if let known = self.cache[line.id] { out.append(known) } else {
                let made = RenderedLine(id: line.id, text: TerminalRenderer.attributed(line.cells))
                self.cache[line.id] = made
                out.append(made)
            }
        }
        if self.cache.count > used.count + 100 { self.cache = self.cache.filter { used.contains($0.key) } }
        if let partial = snapshot.inProgress { out.append(RenderedLine(id: -1, text: TerminalRenderer.attributed(partial.cells))) }
        self.rendered = out
        self.scrollTick &+= 1
    }

    // MARK: - previews and tests

    /// A store with invented output for the still previews: no shell, no Touch ID.
    static func sample(unlocked: Bool) -> TerminalStore {
        let store = TerminalStore(authenticator: TouchIDAuthenticator(), startsSessions: false)
        let text = "\u{1B}[1;32mdemo@mac\u{1B}[0m \u{1B}[34m~/project\u{1B}[0m % vercel ls\r\n"
            + "Vercel CLI 39.0.0\r\n"
            + "> 3 deployments found under \u{1B}[1mdemo-team\u{1B}[0m [412ms]\r\n\r\n"
            + "  Age     Deployment                          Status      Duration\r\n"
            + "  2m      demo-app-1x2y3z.vercel.app          \u{1B}[32m● Ready\u{1B}[0m     48s\r\n"
            + "  1h      demo-app-9k8j7h.vercel.app          \u{1B}[32m● Ready\u{1B}[0m     51s\r\n"
            + "  3h      demo-app-4d5f6g.vercel.app          \u{1B}[31m● Error\u{1B}[0m     12s\r\n\r\n"
            + "\u{1B}[1;32mdemo@mac\u{1B}[0m \u{1B}[34m~/project\u{1B}[0m % aws sts get-caller-identity\r\n"
            + "{\r\n    \"UserId\": \"AIDAEXAMPLE\",\r\n    \"Account\": \"111122223333\",\r\n    \"Arn\": \"arn:aws:iam::111122223333:user/demo\"\r\n}\r\n"
            + "\u{1B}[1;32mdemo@mac\u{1B}[0m \u{1B}[34m~/project\u{1B}[0m % "
        store.buffer.feed(Data(text.utf8))
        store.sessionState = .running
        if unlocked { store.isUnlocked = true; store.flush(force: true) }
        return store
    }

    /// For tests: lets a test open the lock without a fingerprint.
    func debugSetUnlocked(_ value: Bool) { self.isUnlocked = value }
}
