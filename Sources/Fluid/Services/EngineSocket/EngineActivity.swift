import Foundation

/// What the engine is busy with, so background work in myOS (reading messages with the on-device model) can stay out of the
/// way of a recording or a dictation. Booleans only.
nonisolated protocol EngineActivityProviding: Sendable {
    func snapshot() async -> [String: Any]
}

/// Runs `operation` and gives up after `seconds`, returning nil, so one stuck step can never leave a client waiting forever.
/// The stuck work is not cancelled (it may be waiting on the main thread); it is abandoned and its late result is dropped.
nonisolated enum EngineTimeout {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { self.lock.lock(); defer { self.lock.unlock() }; if self.done { return false }; self.done = true; return true }
    }

    static func run<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            Task { let value = await operation(); if once.claim() { continuation.resume(returning: value) } }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if once.claim() { continuation.resume(returning: nil) } }
        }
    }
}

/// Where the activity check last got to, so a stall can say which step it was stuck on.
nonisolated enum ActivityProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var current = "idle"
    static func set(_ step: String) { self.lock.lock(); self.current = step; self.lock.unlock() }
    static var step: String { self.lock.lock(); defer { self.lock.unlock() }; return self.current }
}

nonisolated struct LiveEngineActivity: EngineActivityProviding {
    func snapshot() async -> [String: Any] {
        ActivityProbe.set("waiting for the main thread")
        return await MainActor.run {
            ActivityProbe.set("reading the meeting state")
            var recording = false, processing = false
            if let state = NotchMeetingCardController.shared.engineCoordinator?.state {
                switch state {
                case .preparing, .recording, .recordingDegraded, .stopping: recording = true
                case .processing: processing = true
                case .idle, .completed, .interrupted, .failed: break
                }
            }
            ActivityProbe.set("reading the dictation state")
            let dictating = AppServices.shared.asr.isRunning
            ActivityProbe.set("done")
            return ["recording": recording, "meeting_processing": processing, "dictating": dictating, "busy": recording || processing || dictating]
        }
    }
}
