import Foundation

/// One stretch of something playing: a video in a browser, a song in Spotify. It runs from when the thing started playing to when it paused,
/// changed or stopped.
struct WatchSession: Codable, Equatable {
    var id: String
    /// Same title in the same app is the same item.
    var key: String
    var title: String
    var artist: String?
    var app: String?
    var bundle: String?
    /// The website or app it came from ("YouTube", "Spotify"), when known.
    var site: String?
    var music: Bool
    /// Seconds since 1970.
    var start: Double
    var end: Double
}

/// Keeps every session, with no cap, so a screen time page can add up how long things were watched. Closed sessions are one line each in
/// `sessions.jsonl`; the one in progress lives in `open.json` and is refreshed every minute, so a crash or a quit loses at most a minute.
@MainActor
final class WatchSessionLog {
    private(set) var sessions: [WatchSession] = []
    private var open: WatchSession?
    private var lastBeat: Date?
    private var timer: Timer?
    private let closedURL: URL
    private let openURL: URL

    /// A flicker shorter than this is not a session.
    static let minSeconds: Double = 5
    /// A minute-beat this late means the Mac slept: the session ended when the last beat did.
    static let sleepGap: TimeInterval = 150

    init(directory: URL) {
        self.closedURL = directory.appendingPathComponent("sessions.jsonl")
        self.openURL = directory.appendingPathComponent("open.json")
        self.load()
    }

    private func load() {
        let decoder = JSONDecoder()
        if let text = try? String(contentsOf: self.closedURL, encoding: .utf8) {
            self.sessions = text.split(separator: "\n").compactMap { try? decoder.decode(WatchSession.self, from: Data($0.utf8)) }
        }
        // A session left open by a quit or a crash ends where it was last refreshed.
        if let data = try? Data(contentsOf: self.openURL), let left = try? decoder.decode(WatchSession.self, from: data) {
            self.finish(left)
            try? FileManager.default.removeItem(at: self.openURL)
        }
    }

    /// What is playing now: nil when nothing is. A change of item (or of nothing to something) closes the one before and opens the next.
    func observe(_ now: WatchSession?, at date: Date = Date()) {
        if let now, let current = self.open, current.key == now.key {
            // The same item: details such as the website or the artist can arrive a moment late.
            self.open?.site = now.site ?? current.site
            self.open?.artist = now.artist ?? current.artist
            return
        }
        self.closeOpen(at: date)
        guard var next = now else { return }
        next.start = date.timeIntervalSince1970
        next.end = next.start
        self.open = next
        self.lastBeat = date
        self.saveOpen()
        self.startTimer()
    }

    /// Writes the session in progress as it stands (every minute, and before it is read).
    func beat(at date: Date = Date()) {
        guard var current = self.open else { return }
        if let last = self.lastBeat, date.timeIntervalSince(last) > Self.sleepGap {
            // The Mac slept: what was playing ended at the last beat. If it is still playing, a new session begins now.
            let resume = current
            self.closeOpen(at: last)
            var next = resume
            next.id = UUID().uuidString
            next.start = date.timeIntervalSince1970
            next.end = next.start
            self.open = next
            self.lastBeat = date
            self.saveOpen()
            return
        }
        current.end = max(current.end, date.timeIntervalSince1970)
        self.open = current
        self.lastBeat = date
        self.saveOpen()
    }

    /// The sessions that were still going after `since` (seconds since 1970), the one in progress included as of now.
    func sessions(since: Double?) -> [WatchSession] {
        self.beat()
        let all = self.sessions + (self.open.map { [$0] } ?? [])
        guard let since else { return all }
        return all.filter { $0.end > since }
    }

    private func closeOpen(at date: Date) {
        self.timer?.invalidate()
        self.timer = nil
        guard var current = self.open else { return }
        self.open = nil
        self.lastBeat = nil
        current.end = max(current.end, date.timeIntervalSince1970)
        try? FileManager.default.removeItem(at: self.openURL)
        self.finish(current)
    }

    private func finish(_ session: WatchSession) {
        guard session.end - session.start >= Self.minSeconds else { return }
        self.sessions.append(session)
        guard var line = try? JSONEncoder().encode(session) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: self.closedURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: self.closedURL, options: .atomic)
        }
    }

    private func saveOpen() {
        guard let current = self.open, let data = try? JSONEncoder().encode(current) else { return }
        try? data.write(to: self.openURL, options: .atomic)
    }

    private func startTimer() {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
    }
}
