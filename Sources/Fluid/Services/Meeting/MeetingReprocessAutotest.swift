import Foundation

/// `LAVOIX_MEETING_REPROCESS_AUTOTEST=<a saved meeting's folder>`: runs the real final-processing pipeline (Parakeet speech, Nemotron speakers)
/// again on a COPY of that meeting and prints the transcript, so a change to how the transcript is put together can be measured on real audio
/// without touching the saved meeting or the running app. `LAVOIX_MEETING_REPROCESS_NOPAD=1` turns the speech-activity padding off, to measure
/// what it adds on the same binary.
enum MeetingReprocessAutotest {
    @MainActor static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LAVOIX_MEETING_REPROCESS_AUTOTEST"], !path.isEmpty, path != "0" else { return }
        Task { @MainActor in
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("reprocess-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: scratch)
                // A fresh run: no earlier result, checkpoint or attempt may short-circuit it.
                for name in try FileManager.default.contentsOfDirectory(atPath: scratch.path)
                where name.hasPrefix("result-") || name.lowercased().contains("checkpoint") {
                    try? FileManager.default.removeItem(at: scratch.appendingPathComponent(name))
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var session = try decoder.decode(MeetingSession.self, from: Data(contentsOf: scratch.appendingPathComponent("session.json")))
                session.transcriptSegments = []
                session.processingAttempts = []
                session.resultSidecarReference = nil
                // This process has none of the app's model owners registered, so it must not ask the residency coordinator for admission.
                let pipeline = MeetingProcessingPipeline(
                    asrServiceProvider: { AppServices.shared.asr },
                    managesModelResidency: false,
                    prepareDiarizationModel: { try await MeetingDiarizationModelStore.shared.ensureInstalled() }
                )
                // The speech engine is held for the whole run, as the session coordinator holds it while it processes a meeting.
                let asr = AppServices.shared.asr
                let lease = try asr.acquireExclusiveActivity(.meeting)
                defer { asr.releaseExclusiveActivity(lease) }
                let result = try await pipeline.process(session: session, sessionDirectory: scratch, progress: { print("stage: \($0)") })
                let names = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0.displayName) })
                var words = 0
                for segment in result.segments.sorted(by: { $0.start.seconds < $1.start.seconds }) {
                    let speaker = segment.speakerID.flatMap { names[$0] } ?? "(unassigned)"
                    words += segment.text.split(separator: " ").count
                    print(String(format: "SEG %6.1f-%6.1f %@: %@", segment.start.seconds, segment.end.seconds, speaker, segment.text))
                }
                print("REPROCESS WORDS: \(words) in \(result.segments.count) segments; complete=\(result.isComplete)")
                exit(0)
            } catch {
                print("REPROCESS FAILED: \(error)")
                exit(1)
            }
        }
    }
}
