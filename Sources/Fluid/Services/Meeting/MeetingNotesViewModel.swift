import Combine
import Foundation

/// Backs the meeting notes screen: the user's own notes, the generated notes per style, and the on-device run.
@MainActor
final class MeetingNotesViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case generating(String)
        case failed(String)
    }

    @Published var kind: MeetingSummaryKind = .executive
    @Published private(set) var output = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isStale = false
    @Published private(set) var notes = ""

    nonisolated struct Saved: Codable, Sendable {
        let transcriptHash: String
        let modelID: String
        let text: String
    }

    private var sessionID: MeetingSessionID?
    private var directory: URL?
    private var task: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    var isGenerating: Bool {
        if case .generating = self.phase { return true }
        return false
    }

    // MARK: - Loading

    func load(session: MeetingSession) async {
        guard self.sessionID != session.id else { return }
        self.cancel()
        self.sessionID = session.id
        self.output = ""
        self.isStale = false
        self.phase = .idle
        self.directory = try? await MeetingSessionStore.shared.existingSessionDirectory(for: session.id)
        let directory = self.directory
        self.notes = await Task.detached(priority: .utility) { () -> String in
            guard let directory else { return "" }
            return (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        }.value
        await self.loadSaved(session: session)
    }

    func select(kind: MeetingSummaryKind, session: MeetingSession) async {
        guard !self.isGenerating else { return }
        self.kind = kind
        await self.loadSaved(session: session)
    }

    private func loadSaved(session: MeetingSession) async {
        let directory = self.directory
        let kind = self.kind
        let saved = await Task.detached(priority: .utility) { () -> Saved? in
            guard let directory,
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"))
            else { return nil }
            return try? JSONDecoder().decode(Saved.self, from: data)
        }.value
        guard self.kind == kind else { return }
        self.output = saved?.text ?? ""
        self.isStale = false
        if let saved {
            let transcript = await Task.detached(priority: .utility) { MeetingSummaryInput.transcript(for: session) }.value
            let current = Self.fingerprint(transcript: transcript, notes: self.notes)
            self.isStale = current != saved.transcriptHash
        }
    }

    // MARK: - Notes pad

    func updateNotes(_ text: String) {
        guard text != self.notes else { return }
        self.notes = text
        if !self.output.isEmpty { self.isStale = true }
        self.saveTask?.cancel()
        let directory = self.directory
        self.saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let directory else { return }
            try? await Task.detached(priority: .utility) {
                try text.write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            }.value
        }
    }

    // MARK: - Generating

    func generate(session: MeetingSession, asr: ASRService?) {
        let backend = MeetingNotesBackend.current
        guard !self.isGenerating, backend.isReady,
              let selectionLock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.phase = .generating("Preparing…")
        let kind = self.kind
        let notes = self.notes
        let modelID = backend.modelID
        let command = backend.command
        self.task = Task {
            defer { MeetingSummaryActivityCoordinator.shared.unlockSelection(selectionLock) }
            do {
                let transcript = await Task.detached(priority: .utility) { MeetingSummaryInput.transcript(for: session) }.value
                guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw MeetingNotesError.emptyTranscript
                }
                let run: () async throws -> String = {
                    try await MeetingNotesGenerator.generate(
                        transcript: transcript, kind: kind, userNotes: notes, modelID: modelID, command: command,
                        progress: { message in Task { @MainActor [weak self] in self?.setProgress(message) } }
                    )
                }
                let text: String
                if let asr {
                    text = try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr, work: run)
                } else {
                    text = try await run()
                }
                try Task.checkCancellation()
                self.output = text
                self.isStale = false
                self.phase = .idle
                if let directory = self.directory {
                    let saved = Saved(transcriptHash: Self.fingerprint(transcript: transcript, notes: notes), modelID: modelID, text: text)
                    MeetingReadableFiles.write(
                        MeetingReadableFiles.summaryMarkdown(for: session, text: text, writtenBy: modelID),
                        named: MeetingReadableFiles.summaryFileName(for: kind), in: directory
                    )
                    try? await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(saved).write(
                            to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic
                        )
                    }.value
                }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        self.task?.cancel()
        self.task = nil
        if self.isGenerating { self.phase = .idle }
    }

    private func setProgress(_ message: String) {
        guard self.isGenerating else { return }
        self.phase = .generating(message)
    }

    static func fingerprint(transcript: String, notes: String) -> String {
        MeetingSummaryInput.fingerprint(transcript + "\n[notes]\n" + notes)
    }
}
