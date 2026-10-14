import Combine
import Foundation

/// Writes the executive notes by itself once a meeting has been transcribed, in the same file the notes screen
/// reads, so the notes are already there when the user opens the meeting.
@MainActor
final class MeetingAutoAnalysis: ObservableObject {
    static let shared = MeetingAutoAnalysis()

    enum Status: Equatable {
        case idle
        case writing(String)
        case ready(MeetingSessionID)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    private var task: Task<Void, Never>?

    /// Tests swap these to run the pipeline without the on-device model or the real meeting folder.
    var store: any MeetingSessionStoring = MeetingSessionStore.shared
    var generatorOverride: ((String, String) async throws -> String)?

    private init() {}

    /// Runs for a finished meeting unless auto-notes are off, there is nothing to summarize, or notes already exist.
    func start(session: MeetingSession) {
        self.task?.cancel()
        self.status = .idle
        // The readable transcript is always kept, whether or not notes are written.
        self.writeTranscriptFile(session)
        self.exportToBrain(session, summary: nil)
        self.exportMeetingEvent(session)
        guard SettingsStore.shared.meetingAutoNotesEnabled else { return }
        guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        self.task?.cancel()
        self.status = .writing("Writing notes…")
        self.task = Task { [weak self] in
            await self?.run(session: session)
        }
    }

    private func run(session: MeetingSession) async {
        let kind = MeetingSummaryKind.executive
        let backend = MeetingNotesBackend.current
        guard self.generatorOverride != nil || backend.isReady else {
            self.status = .failed("Download the on-device model to get automatic notes.")
            return
        }
        guard let lock = MeetingSummaryActivityCoordinator.shared.lockSelection() else {
            self.status = .idle
            return
        }
        defer { MeetingSummaryActivityCoordinator.shared.unlockSelection(lock) }
        let modelID = backend.modelID
        let command = backend.command
        do {
            guard let directory = try await self.store.existingSessionDirectory(for: session.id) else {
                self.status = .failed("The meeting folder is missing.")
                return
            }
            let transcript = await Task.detached(priority: .utility) { MeetingSummaryInput.transcript(for: session) }.value
            let notes = await Task.detached(priority: .utility) { () -> String in
                (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            }.value
            let override = self.generatorOverride
            let run: () async throws -> String = {
                if let override { return try await override(transcript, notes) }
                return try await MeetingNotesGenerator.generate(
                    transcript: transcript, kind: kind, userNotes: notes, modelID: modelID, command: command,
                    progress: { message in Task { @MainActor in MeetingAutoAnalysis.shared.setProgress(message) } }
                )
            }
            let text: String
            if override != nil {
                text = try await run()
            } else {
                text = try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: AppServices.shared.asr, work: run)
            }
            try Task.checkCancellation()
            let saved = MeetingNotesViewModel.Saved(
                transcriptHash: MeetingNotesViewModel.fingerprint(transcript: transcript, notes: notes), modelID: modelID, text: text
            )
            try await Task.detached(priority: .utility) {
                try JSONEncoder().encode(saved).write(
                    to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic
                )
            }.value
            MeetingReadableFiles.write(
                MeetingReadableFiles.summaryMarkdown(for: session, text: text, writtenBy: modelID),
                named: MeetingReadableFiles.summaryFileName(for: kind), in: directory
            )
            self.exportToBrain(session, summary: text)
            self.status = .ready(session.id)
            DebugLogger.shared.log("auto-notes written session=\(session.id)", source: "MeetingAutoAnalysis")
        } catch is CancellationError {
            self.status = .idle
        } catch {
            DebugLogger.shared.log("auto-notes failed: \(error.localizedDescription)", source: "MeetingAutoAnalysis")
            self.status = .failed(error.localizedDescription)
        }
    }

    /// Tells myOS who was in the meeting (opaque person ids only), when the recording came from a calendar event.
    func exportMeetingEvent(_ session: MeetingSession) {
        let settings = SettingsStore.shared
        guard settings.meetingBrainExportEnabled,
              let data = ContactsInboxExporter.dataDirectory(brainOverride: settings.meetingBrainFolderOverride) else { return }
        let remembered = MeetingAttendeeRegistry.shared.take(session.id)
        Task.detached(priority: .utility) {
            var ids = remembered?.personIDs ?? []
            var unknown = remembered?.unknown ?? 0
            var calendarID = remembered?.calendarEventID
            // Not started from a calendar event (auto-detected, or started by hand): find the event it overlapped.
            if remembered == nil, let end = session.endedAt,
               let candidates = CalendarLinks.fetch(start: session.startedAt - 3600, end: end + 3600),
               let match = CalendarLinks.bestOverlap(candidates, start: session.startedAt, end: end) {
                let people = PeopleDatabase.emailMap(emails: match.emails)
                ids = Array(Set(match.emails.compactMap { people[$0]?.id }))
                unknown = max(0, match.emails.count - ids.count)
                calendarID = match.id
            }
            guard !ids.isEmpty else { return }
            let payload = MeetingInboxExporter.payload(
                meetingID: session.id, title: session.title, start: session.startedAt, end: session.endedAt,
                personIDs: ids, unknownAttendees: unknown, noteFile: MeetingBrainExporter.fileName(for: session),
                calendarEventID: calendarID
            )
            do { try MeetingInboxExporter.write(payload, meetingID: session.id, start: session.startedAt, dataDirectory: data) }
            catch { DebugLogger.shared.warning("Meeting event export failed: \(error.localizedDescription)", source: "MeetingInbox") }
        }
    }

    /// Copies the meeting into myOS's Brain: creates the note, or refreshes just its summary block.
    func exportToBrain(_ session: MeetingSession, summary: String?) {
        let settings = SettingsStore.shared
        guard settings.meetingBrainExportEnabled,
              let brain = MeetingBrainExporter.brainDirectory(override: settings.meetingBrainFolderOverride),
              session.transcriptSegments.contains(where: { !$0.isEcho }) else { return }
        let store = self.store
        Task.detached(priority: .utility) {
            let directory = try? await store.existingSessionDirectory(for: session.id)
            let notes = directory.flatMap { try? String(contentsOf: $0.appendingPathComponent("notes.md"), encoding: .utf8) } ?? ""
            let transcript = directory?.appendingPathComponent("transcript.md").path
            do {
                try MeetingBrainExporter.upsert(session: session, summary: summary, userNotes: notes, transcriptPath: transcript, brainDirectory: brain)
            } catch {
                DebugLogger.shared.warning("Brain export failed: \(error.localizedDescription)", source: "MeetingBrainExporter")
            }
        }
    }

    private func writeTranscriptFile(_ session: MeetingSession) {
        let store = self.store
        Task.detached(priority: .utility) {
            guard session.transcriptSegments.contains(where: { !$0.isEcho }),
                  let directory = try? await store.existingSessionDirectory(for: session.id) else { return }
            MeetingReadableFiles.write(MeetingReadableFiles.transcriptMarkdown(for: session), named: "transcript.md", in: directory)
        }
    }

    private func setProgress(_ message: String) {
        guard case .writing = self.status else { return }
        self.status = .writing(message)
    }
}
