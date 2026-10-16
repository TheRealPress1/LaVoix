import Foundation

/// What myOS can ask the engine about meetings. Plain dictionaries so the socket can send them as JSON as they are; the
/// live implementation reads the real sessions, the autotest uses a fake.
nonisolated protocol EngineMeetingsProviding: Sendable {
    func list() async throws -> [[String: Any]]
    func get(id: UUID) async throws -> [String: Any]?
    func saveNotes(id: UUID, text: String) async throws
    /// Writes the notes for a meeting, reporting `progress`/`skipped`/`done`/`error` events as it goes. `emit` returns false
    /// when the listener has gone away, which stops the work. `auto` applies the same rules as opening a meeting in the
    /// app (recent, finished, no notes yet, tried once).
    func generateNotes(id: UUID, kind: String, auto: Bool, emit: @escaping @Sendable ([String: Any]) -> Bool) async throws
}

nonisolated enum EngineMeetingsError: LocalizedError {
    case notFound, noTranscript, modelMissing, busy
    var errorDescription: String? {
        switch self {
        case .notFound: "That meeting no longer exists."
        case .noTranscript: "This meeting has no transcript text to write notes from."
        case .modelMissing: "Download the on-device model (or set a notes command) to get notes."
        case .busy: "Notes are already being written."
        }
    }
}

nonisolated struct LiveEngineMeetings: EngineMeetingsProviding {
    var store: any MeetingSessionStoring = MeetingSessionStore.shared

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func words(_ session: MeetingSession) -> Int {
        session.transcriptSegments.filter { !$0.isEcho }.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    func list() async throws -> [[String: Any]] {
        let sessions = try await self.store.loadAllForDisplay().filter { $0.state != .preparing }.sorted { $0.startedAt > $1.startedAt }
        var rows: [[String: Any]] = []
        for s in sessions {
            let directory = try? await self.store.existingSessionDirectory(for: s.id)
            let hasSummary = directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manual-summary-executive.json").path) } ?? false
            rows.append([
                "id": s.id.uuidString, "title": s.title, "started_at": Self.iso(s.startedAt),
                "ended_at": s.endedAt.map(Self.iso) ?? NSNull(), "duration_seconds": Int(max(0, s.duration)),
                "state": s.state.rawValue, "speakers": s.activeSpeakers.count, "words": Self.words(s),
                "has_summary": hasSummary, "source": s.capturedApplication?.displayName ?? "", "mode": s.mode.rawValue,
            ])
        }
        return rows
    }

    func get(id: UUID) async throws -> [String: Any]? {
        guard let s = try await self.store.loadForDisplay(id: id) else { return nil }
        let directory = try await self.store.existingSessionDirectory(for: id)
        let names = Dictionary(uniqueKeysWithValues: s.speakers.map { ($0.id, ($0.displayName, $0.isLocalUser)) })
        let segments: [[String: Any]] = s.transcriptSegments.filter { !$0.isEcho }.sorted { $0.start.seconds < $1.start.seconds }.map { seg in
            let who = seg.speakerID.flatMap { names[$0] }
            return ["start": seg.start.seconds, "end": seg.end.seconds, "speaker": who?.0 ?? "Unknown", "is_me": who?.1 ?? false, "text": seg.text]
        }
        var summaries: [String: Any] = [:]
        var notes = ""
        if let directory {
            notes = (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            let transcript = MeetingSummaryInput.transcript(for: s)
            let current = MeetingSummaryInput.fingerprint(transcript + "\n[notes]\n" + notes)
            for kind in MeetingSummaryKind.allCases {
                let file = directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")
                guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(MeetingNotesViewModel.Saved.self, from: data) else { continue }
                summaries[kind.rawValue] = ["text": saved.text, "model": saved.modelID, "stale": saved.transcriptHash != current]
            }
        }
        return [
            "id": s.id.uuidString, "title": s.title, "started_at": Self.iso(s.startedAt), "ended_at": s.endedAt.map(Self.iso) ?? NSNull(),
            "duration_seconds": Int(max(0, s.duration)), "state": s.state.rawValue, "source": s.capturedApplication?.displayName ?? "",
            "mode": s.mode.rawValue, "words": Self.words(s),
            "speakers": s.activeSpeakers.map { ["name": $0.displayName, "is_me": $0.isLocalUser] as [String: Any] },
            "segments": segments, "summaries": summaries, "notes": notes,
            "kinds": MeetingSummaryKind.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "audio_saved": directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tracks").path) } ?? false,
        ]
    }

    func saveNotes(id: UUID, text: String) async throws {
        guard let directory = try await self.store.existingSessionDirectory(for: id) else { throw EngineMeetingsError.notFound }
        try text.write(to: directory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
    }

    func generateNotes(id: UUID, kind rawKind: String, auto: Bool, emit: @escaping @Sendable ([String: Any]) -> Bool) async throws {
        guard let session = try await self.store.load(id: id), let directory = try await self.store.existingSessionDirectory(for: id) else {
            throw EngineMeetingsError.notFound
        }
        let kind = MeetingSummaryKind(rawValue: rawKind) ?? .executive
        guard Self.words(session) >= (auto ? 40 : 1) else {
            if auto { _ = emit(["event": "skipped", "reason": "no transcript"]); return }
            throw EngineMeetingsError.noTranscript
        }
        if auto {
            let hasSummary = FileManager.default.fileExists(atPath: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json").path)
            let marker = directory.appendingPathComponent("auto-notes-attempted")
            let enabled = await MainActor.run { SettingsStore.shared.meetingAutoNotesEnabled }
            let recent = session.endedAt.map { Date().timeIntervalSince($0) < MeetingNotesViewModel.autoNotesMaxAge } ?? false
            guard enabled, kind == .executive, !hasSummary, session.state == .completed, recent,
                  !FileManager.default.fileExists(atPath: marker.path) else {
                _ = emit(["event": "skipped", "reason": "not needed"]); return
            }
            try? Data().write(to: marker)
        }
        let backend = await MainActor.run { MeetingNotesBackend.current }
        guard backend.isReady else { throw EngineMeetingsError.modelMissing }
        guard let lock = await MainActor.run(body: { MeetingSummaryActivityCoordinator.shared.lockSelection() }) else { throw EngineMeetingsError.busy }
        defer { Task { @MainActor in MeetingSummaryActivityCoordinator.shared.unlockSelection(lock) } }

        _ = emit(["event": "progress", "message": "Preparing…"])
        let notes = (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
        let transcript = MeetingSummaryInput.transcript(for: session)
        let run: () async throws -> String = {
            try await MeetingNotesGenerator.generate(
                transcript: transcript, kind: kind, userNotes: notes, modelID: backend.modelID, command: backend.command,
                progress: { message in _ = emit(["event": "progress", "message": message]) }
            )
        }
        let text = try await MeetingSummaryActivityCoordinator.shared.withSummaryWhenFree(
            activity: AppServices.shared.asr,
            onWaiting: { _ = emit(["event": "progress", "message": "Waiting for the transcription to finish…"]) },
            work: run
        )
        let saved = MeetingNotesViewModel.Saved(transcriptHash: MeetingSummaryInput.fingerprint(transcript + "\n[notes]\n" + notes), modelID: backend.modelID, text: text)
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
        MeetingReadableFiles.write(
            MeetingReadableFiles.summaryMarkdown(for: session, text: text, writtenBy: backend.modelID),
            named: MeetingReadableFiles.summaryFileName(for: kind), in: directory
        )
        if kind == .executive { await MainActor.run { MeetingAutoAnalysis.shared.exportToBrain(session, summary: text) } }
        _ = emit(["event": "done", "text": text])
    }
}
