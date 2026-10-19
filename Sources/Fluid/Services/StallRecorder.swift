import AppKit
import Foundation

/// Catches a freeze in the act. The main thread beats a heartbeat ten times a second; a second thread watches it. If the beat stops for
/// about a second, it asks macOS for a two-second snapshot of what the app is doing and saves it next to the log, so a freeze can be
/// explained afterwards instead of guessed at. At most one snapshot every ninety seconds, and the newest ten are kept.
nonisolated final class StallRecorder: @unchecked Sendable {
    static let shared = StallRecorder()

    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    private var lastCapture = -1000.0
    private var started = false

    static let thresholdSeconds = 0.9
    static let minGapSeconds = 90.0
    static let keep = 10

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fluid", isDirectory: true)
    }

    /// Whether a stall of this length, this long after the last snapshot, deserves a new one. Pure, so it can be tested.
    static func shouldCapture(stalledFor: Double, sinceLastCapture: Double) -> Bool {
        stalledFor >= self.thresholdSeconds && sinceLastCapture >= self.minGapSeconds
    }

    func start() {
        self.lock.lock()
        if self.started { self.lock.unlock(); return }
        self.started = true
        self.lock.unlock()
        DispatchQueue.main.async {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.beat() }
            RunLoop.main.add(timer, forMode: .common)
        }
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "StallRecorder"
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                self?.check()
            }
        }
    }

    private func beat() {
        self.lock.lock()
        self.lastBeat = ProcessInfo.processInfo.systemUptime
        self.lock.unlock()
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        self.lock.lock()
        let stalled = now - self.lastBeat
        let since = now - self.lastCapture
        let go = Self.shouldCapture(stalledFor: stalled, sinceLastCapture: since)
        if go { self.lastCapture = now }
        self.lock.unlock()
        if go { self.capture(stalledFor: stalled) }
    }

    private func capture(stalledFor: Double) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = Self.directory.appendingPathComponent("stall-\(stamp.string(from: Date())).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        DebugLogger.shared.warning("The main thread was stuck for \(String(format: "%.1f", stalledFor)) s; a snapshot is being saved to \(file.lastPathComponent)", source: "StallRecorder")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) { Self.prune() }
    }

    private static func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []).filter { $0.hasPrefix("stall-") && $0.hasSuffix(".txt") }.sorted()
        for old in files.dropLast(self.keep) { try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(old)) }
    }
}
