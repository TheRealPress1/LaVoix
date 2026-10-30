import Contacts
import Foundation

/// What myOS can ask the engine about meetings. Plain dictionaries so the socket can send them as JSON as they are; the
/// live implementation reads the real sessions, the autotest uses a fake.
nonisolated protocol EngineMeetingsProviding: Sendable {
    func list() async throws -> [[String: Any]]
    func get(id: UUID) async throws -> [String: Any]?
    func saveNotes(id: UUID, text: String) async throws
    /// The recording in progress, if any: running time and the latest live captions.
    func live() async -> [String: Any]
    /// Writes the notes for a meeting, reporting `progress`/`skipped`/`done`/`error` events as it goes. `emit` returns false
    /// when the listener has gone away, which stops the work. `auto` applies the same rules as opening a meeting in the
    /// app (recent, finished, no notes yet, tried once).
    func generateNotes(id: UUID, kind: String, auto: Bool, emit: @escaping @Sendable ([String: Any]) -> Bool) async throws
    /// Starts recording now (an online call in the app you are using, or a conversation in the room). Returns the new meeting.
    func start(title: String, online: Bool) async throws -> [String: Any]
    /// Stops the recording in progress; transcription and notes follow by themselves.
    func stop() async throws
    func renameSpeaker(id: UUID, speakerID: UUID, name: String) async throws
    func rename(id: UUID, title: String) async throws
    func delete(id: UUID) async throws
    /// Your verdict on a set of notes: "good", "bad", or "edited" with your corrected `text` (which also replaces the notes).
    func rateNotes(id: UUID, kind: String, rating: String, text: String?) async throws
}

nonisolated enum EngineMeetingsError: LocalizedError {
    case notFound, noTranscript, modelMissing, busy, recordingBusy, notRecording, badName, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .recordingBusy: "A recording or its processing is already in progress."
        case .notRecording: "Nothing is being recorded."
        case .badName: "Give it a name of one to eighty characters."
        case let .unavailable(m): m
        case .notFound: "That meeting no longer exists."
        case .noTranscript: "This meeting has no transcript text to write notes from."
        case .modelMissing: "Download the on-device model (or set a notes command) to get notes."
        case .busy: "Notes are already being written."
        }
    }
}

/// Someone who was invited to a meeting, from the calendar. Kept in the meeting's own folder (`attendees.json`), never in
/// the iCloud-synced data folder, because it holds an email address.
nonisolated struct MeetingAttendee: Codable, Equatable {
    var name: String
    var email: String
    /// Small contact photo (base64), when the address book has one for this email.
    var photo: String?
    /// Set for people found in the event description (no email there): their LinkedIn page and role.
    var linkedin: String? = nil
    var role: String? = nil
}

nonisolated enum MeetingAttendees {
    static func file(in directory: URL) -> URL { directory.appendingPathComponent("attendees.json") }

    static func load(from directory: URL) -> [MeetingAttendee]? {
        (try? Data(contentsOf: self.file(in: directory))).flatMap { try? JSONDecoder().decode([MeetingAttendee].self, from: $0) }
    }

    /// "jane.doe@x.com" -> "Jane Doe", for invitees whose calendar entry carries no name.
    static func nameFromEmail(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local.split(whereSeparator: { ".-_".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func photo(forEmail email: String) -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor]
        let contact = try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys).first
        return contact?.thumbnailImageData?.base64EncodedString()
    }

    /// People some tools list in the event description instead of inviting them, like
    /// "Jane Doe (GTM Recruiter, LinkedIn)". Needs a name and a role in brackets and a LinkedIn mention, so ordinary
    /// text in a description is not mistaken for a person. Returns name, role and (when linked) the LinkedIn address.
    static func peopleFromDescription(_ text: String) -> [(name: String, role: String, linkedin: String?)] {
        let namePart = #"([\p{Lu}][\p{L}'’.\-]+(?:\s+[\p{Lu}][\p{L}'’.\-]+){1,3})"#
        let pattern = namePart + #"\s*\(([^()<>]*?)(?:,\s*)?(?:<a[^>]*href="([^"]*linkedin\.com/in/[^"?]*)[^"]*"[^>]*>[^<]*</a>|(https?://[^\s)<"]*linkedin\.com/in/[^\s)<"?]*)|LinkedIn)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        var out: [(String, String, String?)] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let role = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let link = [3, 4].compactMap { m.range(at: $0).location != NSNotFound ? ns.substring(with: m.range(at: $0)) : nil }.first
            if !out.contains(where: { $0.0 == name }) { out.append((name, role, link)) }
        }
        return out
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var inFlight = Set<UUID>()

    /// Looks the meeting up in the calendar once, in the background, and saves who was invited. For a one-on-one it also
    /// names the call's speaker after that person (and yours "Me"), which sticks in the session itself.
    static func resolveInBackground(session: MeetingSession, directory: URL, store: any MeetingSessionStoring) {
        self.lock.lock()
        let fresh = self.inFlight.insert(session.id).inserted
        self.lock.unlock()
        guard fresh, let end = session.endedAt else { return }
        Task.detached(priority: .utility) {
            defer { self.lock.lock(); self.inFlight.remove(session.id); self.lock.unlock() }
            guard let candidates = CalendarLinks.fetchAll(start: session.startedAt - 3600, end: end + 3600),
                  let match = CalendarLinks.bestOverlap(candidates, start: session.startedAt, end: end) else {
                try? JSONEncoder().encode([MeetingAttendee]()).write(to: self.file(in: directory)) // looked, found nothing
                return
            }
            var attendees = match.emails.map {
                MeetingAttendee(name: match.names[$0].flatMap { $0.contains("@") ? nil : $0 } ?? self.nameFromEmail($0), email: $0, photo: self.photo(forEmail: $0))
            }
            if attendees.isEmpty, let notes = match.notes {
                attendees = self.peopleFromDescription(notes).map { MeetingAttendee(name: $0.name, email: "", photo: nil, linkedin: $0.linkedin, role: $0.role.isEmpty ? nil : $0.role) }
            }
            try? JSONEncoder().encode(attendees).write(to: self.file(in: directory), options: .atomic)
            guard attendees.count == 1, var current = try? await store.load(id: session.id) else { return }
            let remote = current.speakers.filter { $0.mergedIntoSpeakerID == nil && $0.trackKind == .applicationAudio }
            let mine = current.speakers.filter { $0.mergedIntoSpeakerID == nil && $0.trackKind == .microphone }
            var changed = false
            if remote.count == 1, remote[0].displayName.hasPrefix("Speaker"), (try? current.renameSpeaker(id: remote[0].id, to: attendees[0].name)) != nil { changed = true }
            if mine.count == 1, mine[0].displayName.hasPrefix("Speaker"), (try? current.renameSpeaker(id: mine[0].id, to: "Me")) != nil { changed = true }
            if changed {
                try? await store.save(current)
                // Notes written before the speakers had names say "Speaker 1"; write them again with the real names.
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manual-summary-executive.json").path) {
                    try? await LiveEngineMeetings(store: store).generateNotes(id: session.id, kind: "executive", auto: false, emit: { _ in true })
                }
            }
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
            return ["id": seg.id.uuidString, "speaker_id": seg.speakerID?.uuidString ?? NSNull(), "start": seg.start.seconds, "end": seg.end.seconds, "speaker": who?.0 ?? "Unknown", "is_me": who?.1 ?? false, "text": seg.text]
        }
        var summaries: [String: Any] = [:]
        var notes = ""
        var attendees: [[String: Any]] = []
        if let directory, s.state == .completed {
            if let known = MeetingAttendees.load(from: directory)?.filter({ !CalendarLinks.myEmails.contains($0.email.lowercased()) }) {
                attendees = known.map { ["name": $0.name, "email": $0.email, "photo": $0.photo ?? NSNull(), "linkedin": $0.linkedin ?? NSNull(), "role": $0.role ?? NSNull()] as [String: Any] }
            } else {
                MeetingAttendees.resolveInBackground(session: s, directory: directory, store: self.store)
            }
        }
        if let directory {
            notes = (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
            let transcript = MeetingSummaryInput.transcript(for: s)
            let current = MeetingSummaryInput.fingerprint(transcript + "\n[notes]\n" + notes)
            for kind in MeetingSummaryKind.allCases {
                let file = directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")
                guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(MeetingNotesViewModel.Saved.self, from: data) else { continue }
                summaries[kind.rawValue] = ["text": saved.text, "model": saved.modelID, "stale": saved.transcriptHash != current,
                                            "rating": TrainingData.rating(meeting: id, kind: kind.rawValue) ?? NSNull(),
                                            "can_rate": TrainingData.canRate(meeting: id, kind: kind.rawValue, notes: saved.text)] as [String: Any]
            }
        }
        return [
            "id": s.id.uuidString, "title": s.title, "started_at": Self.iso(s.startedAt), "ended_at": s.endedAt.map(Self.iso) ?? NSNull(),
            "duration_seconds": Int(max(0, s.duration)), "state": s.state.rawValue, "source": s.capturedApplication?.displayName ?? "",
            "mode": s.mode.rawValue, "words": Self.words(s),
            "speakers": s.activeSpeakers.map { ["id": $0.id.uuidString, "name": $0.displayName, "is_me": $0.isLocalUser] as [String: Any] },
            "segments": segments, "summaries": summaries, "notes": notes, "attendees": attendees, "note_file": MeetingBrainExporter.fileName(for: s),
            "kinds": MeetingSummaryKind.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "audio_saved": directory.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("tracks").path) } ?? false,
        ]
    }

    func live() async -> [String: Any] {
        await MainActor.run { NotchMeetingCardController.shared.engineLiveState() }
    }

    private static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw EngineMeetingsError.badName }
        return name
    }

    func start(title: String, online: Bool) async throws -> [String: Any] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await NotchMeetingCardController.shared.engineStart(title: String(name.prefix(80)), online: online)
        return ["id": session.id.uuidString, "title": session.title]
    }

    func stop() async throws {
        try await NotchMeetingCardController.shared.engineStop()
    }

    func renameSpeaker(id: UUID, speakerID: UUID, name: String) async throws {
        let clean = try Self.cleanName(name)
        guard let coordinator = await NotchMeetingCardController.shared.engineCoordinator else { throw EngineMeetingsError.unavailable("The meeting engine is not ready yet.") }
        do { _ = try await coordinator.renameSpeaker(sessionID: id, speakerID: speakerID, to: clean) } catch { throw EngineMeetingsError.unavailable(error.localizedDescription) }
    }

    func rename(id: UUID, title: String) async throws {
        let clean = try Self.cleanName(title)
        guard let coordinator = await NotchMeetingCardController.shared.engineCoordinator else { throw EngineMeetingsError.unavailable("The meeting engine is not ready yet.") }
        do { _ = try await coordinator.renameSession(sessionID: id, to: clean) } catch { throw EngineMeetingsError.unavailable(error.localizedDescription) }
    }

    func delete(id: UUID) async throws {
        guard let coordinator = await NotchMeetingCardController.shared.engineCoordinator else { throw EngineMeetingsError.unavailable("The meeting engine is not ready yet.") }
        do { try await coordinator.deleteSession(id: id) } catch { throw EngineMeetingsError.unavailable(error.localizedDescription) }
    }

    func rateNotes(id: UUID, kind: String, rating rawRating: String, text: String?) async throws {
        guard let rating = TrainingData.Rating(rawValue: rawRating) else { throw TrainingData.Failure.badRating }
        guard MeetingSummaryKind(rawValue: kind) != nil, let directory = try await self.store.existingSessionDirectory(for: id) else { throw EngineMeetingsError.notFound }
        let file = directory.appendingPathComponent("manual-summary-\(kind).json")
        guard let data = try? Data(contentsOf: file), var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let notes = saved["text"] as? String else { throw EngineMeetingsError.notFound }
        try TrainingData.rate(meeting: id, kind: kind, rating: rating, notes: notes, corrected: text)
        if rating == .edited, let text {
            // The notes you see are now your version.
            saved["text"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try JSONSerialization.data(withJSONObject: saved).write(to: file, options: .atomic)
        }
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
        let marker = directory.appendingPathComponent("auto-notes-attempted")
        if auto {
            let hasSummary = FileManager.default.fileExists(atPath: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json").path)
            let enabled = await MainActor.run { SettingsStore.shared.meetingAutoNotesEnabled }
            let recent = session.endedAt.map { Date().timeIntervalSince($0) < MeetingNotesViewModel.autoNotesMaxAge } ?? false
            guard enabled, kind == .executive, !hasSummary, session.state == .completed, recent,
                  !FileManager.default.fileExists(atPath: marker.path) else {
                _ = emit(["event": "skipped", "reason": "not needed"]); return
            }
        }
        let backend = await MainActor.run { MeetingNotesBackend.current }
        guard backend.isReady else { throw EngineMeetingsError.modelMissing }
        guard let lock = await MainActor.run(body: { MeetingSummaryActivityCoordinator.shared.lockSelection() }) else { throw EngineMeetingsError.busy }
        defer { Task { @MainActor in MeetingSummaryActivityCoordinator.shared.unlockSelection(lock) } }
        // The one automatic attempt is spent only now that the notes really are about to be written. Written earlier, an attempt that found no
        // model (the FT call of 2026-10-30) or found another run holding the writer used it up, and the meeting never got notes by itself.
        if auto { try? Data().write(to: marker) }

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
