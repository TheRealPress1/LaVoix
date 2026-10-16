import Foundation

/// What the engine is busy with, so background work in myOS (reading messages with the on-device model) can stay out of the
/// way of a recording or a dictation. Booleans only.
nonisolated protocol EngineActivityProviding: Sendable {
    func snapshot() async -> [String: Any]
}

nonisolated struct LiveEngineActivity: EngineActivityProviding {
    func snapshot() async -> [String: Any] {
        await MainActor.run {
            var recording = false, processing = false
            if let state = NotchMeetingCardController.shared.engineCoordinator?.state {
                switch state {
                case .preparing, .recording, .recordingDegraded, .stopping: recording = true
                case .processing: processing = true
                case .idle, .completed, .interrupted, .failed: break
                }
            }
            let dictating = AppServices.shared.asr.isRunning
            return ["recording": recording, "meeting_processing": processing, "dictating": dictating, "busy": recording || processing || dictating]
        }
    }
}
