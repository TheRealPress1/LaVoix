import Foundation

/// The custom dictionary for myOS: words the speech recognizer mishears, and what to type instead. Plain dictionaries so the
/// socket sends them as JSON; the live implementation edits the real list, the autotest uses a fake.
nonisolated protocol EngineDictionaryProviding: Sendable {
    func list() async -> [[String: Any]]
    /// Adds an entry (no `id`) or replaces one. Returns the saved entry, or throws `EngineDictionaryError`.
    func save(id: UUID?, triggers: [String], replacement: String) async throws -> [String: Any]
    func delete(id: UUID) async throws
}

nonisolated enum EngineDictionaryError: LocalizedError, Equatable {
    case noTriggers, tooMany, tooLong, noReplacement, duplicate(String), notFound
    var errorDescription: String? {
        switch self {
        case .noTriggers: "Add at least one word or phrase that gets misheard."
        case .tooMany: "An entry can have up to 20 misheard phrases."
        case .tooLong: "A phrase can be up to 80 characters, and the replacement up to 400."
        case .noReplacement: "Add the text to type instead."
        case let .duplicate(t): "“\(t)” is already used by another entry."
        case .notFound: "That entry no longer exists."
        }
    }
}

/// The rules for an entry, kept apart from the store so they can be tested on their own.
nonisolated enum DictionaryRules {
    /// Cleans and checks an entry against the entries already saved (leaving out the one being edited).
    static func validate(triggers: [String], replacement: String, others: [(id: UUID, triggers: [String])]) throws -> (triggers: [String], replacement: String) {
        var clean: [String] = []
        for raw in triggers {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t.isEmpty || clean.contains(t) { continue }
            guard t.count <= 80 else { throw EngineDictionaryError.tooLong }
            clean.append(t)
        }
        guard !clean.isEmpty else { throw EngineDictionaryError.noTriggers }
        guard clean.count <= 20 else { throw EngineDictionaryError.tooMany }
        guard replacement.count <= 400 else { throw EngineDictionaryError.tooLong }
        guard !replacement.isEmpty else { throw EngineDictionaryError.noReplacement }
        for t in clean where others.contains(where: { $0.triggers.contains(t) }) { throw EngineDictionaryError.duplicate(t) }
        return (clean, replacement)
    }
}

nonisolated struct LiveEngineDictionary: EngineDictionaryProviding {
    private static func describe(_ e: SettingsStore.CustomDictionaryEntry) -> [String: Any] {
        ["id": e.id.uuidString, "triggers": e.triggers, "replacement": e.replacement]
    }

    func list() async -> [[String: Any]] {
        await MainActor.run { SettingsStore.shared.customDictionaryEntries.map(Self.describe) }
    }

    func save(id: UUID?, triggers: [String], replacement: String) async throws -> [String: Any] {
        try await MainActor.run {
            var entries = SettingsStore.shared.customDictionaryEntries
            let others = entries.filter { $0.id != id }.map { (id: $0.id, triggers: $0.triggers) }
            let valid = try DictionaryRules.validate(triggers: triggers, replacement: SettingsStore.CustomDictionaryEntry.sanitizedReplacement(replacement), others: others)
            let saved: SettingsStore.CustomDictionaryEntry
            if let id {
                guard let index = entries.firstIndex(where: { $0.id == id }) else { throw EngineDictionaryError.notFound }
                saved = SettingsStore.CustomDictionaryEntry(id: id, triggers: valid.triggers, replacement: valid.replacement)
                entries[index] = saved
            } else {
                saved = SettingsStore.CustomDictionaryEntry(triggers: valid.triggers, replacement: valid.replacement)
                entries.insert(saved, at: 0)
            }
            Self.persist(entries)
            return Self.describe(saved)
        }
    }

    func delete(id: UUID) async throws {
        try await MainActor.run {
            var entries = SettingsStore.shared.customDictionaryEntries
            guard entries.contains(where: { $0.id == id }) else { throw EngineDictionaryError.notFound }
            entries.removeAll { $0.id == id }
            Self.persist(entries)
        }
    }

    /// Same steps as the dictionary page: save, drop the cached patterns so it takes effect now, tell the recognizer.
    @MainActor private static func persist(_ entries: [SettingsStore.CustomDictionaryEntry]) {
        SettingsStore.shared.customDictionaryEntries = entries
        ASRService.invalidateDictionaryCache()
        NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
    }
}
