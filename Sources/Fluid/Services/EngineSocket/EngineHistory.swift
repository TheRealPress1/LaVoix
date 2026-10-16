import Foundation

/// What myOS can ask the engine about dictation history (what you said, and what it became). Plain dictionaries so the socket
/// sends them as JSON; the live implementation reads the real store, the autotest uses a fake.
nonisolated protocol EngineHistoryProviding: Sendable {
    func list(search: String, starredOnly: Bool, limit: Int) async -> [String: Any]
    func toggleStar(id: UUID) async
    func delete(id: UUID) async
    func clearAll() async
}

nonisolated struct LiveEngineHistory: EngineHistoryProviding {
    func list(search: String, starredOnly: Bool, limit: Int) async -> [String: Any] {
        await MainActor.run {
            let store = TranscriptionHistoryStore.shared
            let found = store.search(query: search, starredOnly: starredOnly, pinnedFirst: true)
            let rows: [[String: Any]] = found.prefix(min(max(limit, 1), 500)).map { e in
                [
                    "id": e.id.uuidString, "timestamp": e.timestamp.timeIntervalSince1970,
                    "raw_text": e.rawText, "processed_text": e.processedText,
                    "app_name": e.appName, "window_title": e.windowTitle,
                    "characters": e.characterCount, "ai_processed": e.wasAIProcessed,
                    "model": e.processingModel ?? "", "ai_error": e.aiProcessingError ?? "",
                    "transcription_ms": e.transcriptionDurationMilliseconds ?? 0,
                    "starred": e.isStarred, "has_audio": e.audio != nil,
                ]
            }
            return [
                "entries": rows, "matched": found.count, "total": store.entries.count,
                "today_words": store.todaySummary.words, "today_transcriptions": store.todaySummary.transcriptions,
                "loading": store.isLoading, "error": store.persistenceError ?? "",
            ]
        }
    }

    func toggleStar(id: UUID) async { await MainActor.run { TranscriptionHistoryStore.shared.toggleStar(id: id) } }
    func delete(id: UUID) async { await MainActor.run { TranscriptionHistoryStore.shared.deleteEntry(id: id) } }
    func clearAll() async { await MainActor.run { TranscriptionHistoryStore.shared.clearAllHistory() } }
}
