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
    /// Transcribes a finished meeting again from its recorded audio, in `language` ("auto" listens and decides, a code such as "fr" or
    /// "en" is the person's choice and sticks; nil keeps what the meeting has). Starts the work and returns; the meeting shows as
    /// being transcribed until it is done.
    func retranscribe(id: UUID, language: String?) async throws
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

    func retranscribe(id: UUID, language: String?) async throws {
        let c = try await self.coordinator()
        if let language, language != "auto", !VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(language) {
            throw EngineMeetingsError.unavailable("That language is not supported. Choose one of the 25 languages of the multilingual speech model, or auto.")
        }
        let busy = await MainActor.run { c.isRecording || c.isProcessing }
        guard !busy else {
            throw EngineMeetingsError.unavailable("A meeting is being recorded or transcribed right now. Try again when it has finished.")
        }
        guard let session = try await self.store.loadForDisplay(id: id) else { throw EngineMeetingsError.notFound }
        let retryable = await MainActor.run { session.hasRetryableAudio }
        guard retryable else {
            throw EngineMeetingsError.unavailable("The audio of this meeting is no longer on this Mac, so it cannot be transcribed again.")
        }
        if language != nil, language != "en", !ParakeetSpeechModelCatalog.v3.isInstalledOnThisMac {
            throw EngineMeetingsError.unavailable("The multilingual speech model is not installed. Install \"Parakeet TDT v3 (Multilingual)\" first, then try again.")
        }
        // The work takes minutes: start it and answer. Progress and any failure show on the meeting itself.
        Task { @MainActor in _ = try? await c.retryProcessing(sessionID: id, language: language) }
    }

    func export(id: UUID, format: String) async throws -> String {
        guard format == "text" || format == "json" else { throw EngineMeetingsError.unavailable("Format must be text or json.") }
        guard let session = try await self.store.loadForDisplay(id: id) else { throw EngineMeetingsError.notFound }
        if format == "json" { return String(decoding: try MeetingTranscriptExporter.json(for: session), as: UTF8.self) }
        return MeetingTranscriptExporter.text(for: session)
    }
}
