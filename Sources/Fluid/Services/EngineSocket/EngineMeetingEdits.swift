import Foundation

/// Fixing a finished meeting and taking it out as text: merge two speakers, give a line to a different speaker, undo the last such
/// fix, and export the transcript. The same engine calls the LaVoix meeting page uses. The live version works on the real sessions,
/// the autotest uses a fake.
nonisolated protocol EngineMeetingEditsProviding: Sendable {
    func mergeSpeakers(id: UUID, source: UUID, into target: UUID) async throws
    func reassign(id: UUID, segment: UUID, to speaker: UUID) async throws
    func undo(id: UUID) async throws
    /// The transcript as "text" (readable, with times and names) or "json".
    func export(id: UUID, format: String) async throws -> String
}

nonisolated struct LiveEngineMeetingEdits: EngineMeetingEditsProviding {
    var store: any MeetingSessionStoring = MeetingSessionStore.shared

    private func coordinator() async throws -> MeetingSessionCoordinator {
        guard let coordinator = await NotchMeetingCardController.shared.engineCoordinator else { throw EngineMeetingsError.unavailable("The meeting engine is not ready yet.") }
        return coordinator
    }

    private func wrap<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch let e as EngineMeetingsError { throw e } catch { throw EngineMeetingsError.unavailable(error.localizedDescription) }
    }

    func mergeSpeakers(id: UUID, source: UUID, into target: UUID) async throws {
        guard source != target else { throw EngineMeetingsError.unavailable("Pick a different speaker to merge into.") }
        let c = try await self.coordinator()
        _ = try await self.wrap { try await c.mergeSpeakers(sessionID: id, source: source, into: target) }
    }

    func reassign(id: UUID, segment: UUID, to speaker: UUID) async throws {
        let c = try await self.coordinator()
        _ = try await self.wrap { try await c.reassignSegment(sessionID: id, segmentID: segment, to: speaker) }
    }

    func undo(id: UUID) async throws {
        let c = try await self.coordinator()
        _ = try await self.wrap { try await c.undoTranscriptCorrection(sessionID: id) }
    }

    func export(id: UUID, format: String) async throws -> String {
        guard format == "text" || format == "json" else { throw EngineMeetingsError.unavailable("Format must be text or json.") }
        guard let session = try await self.store.loadForDisplay(id: id) else { throw EngineMeetingsError.notFound }
        if format == "json" { return String(decoding: try MeetingTranscriptExporter.json(for: session), as: UTF8.self) }
        return MeetingTranscriptExporter.text(for: session)
    }
}
