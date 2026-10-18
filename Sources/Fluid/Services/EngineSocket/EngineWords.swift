import Foundation

/// The recognizer's boost words (names and terms it should favour) plus moving the whole dictionary in and out as a file. Plain
/// dictionaries so the socket sends them as JSON; the live version edits the real list, the autotest uses a fake.
nonisolated protocol EngineWordsProviding: Sendable {
    func list() async -> [[String: Any]]
    func add(text: String, aliases: [String]) async throws -> [String: Any]
    func delete(text: String) async throws
    /// The dictionary as the JSON file LaVoix exports (replacements and boost words).
    func export() async throws -> String
    /// Merges or replaces from such a file. Returns how many replacements and words there are afterwards.
    func importFile(_ json: String, replace: Bool) async throws -> [String: Any]
}

nonisolated enum EngineWordsError: LocalizedError, Equatable {
    case empty, tooLong, tooMany, notFound, unreadable
    var errorDescription: String? {
        switch self {
        case .empty: "Type the word or name first."
        case .tooLong: "A word can be up to 60 characters, with up to 10 ways it is misheard."
        case .tooMany: "You can keep up to 256 words."
        case .notFound: "That word is no longer in the list."
        case .unreadable: "That is not a LaVoix dictionary file."
        }
    }
}

nonisolated enum WordRules {
    static let maxWords = 256

    /// A cleaned word and its alternatives, or why it is refused.
    static func clean(text: String, aliases: [String]) throws -> (text: String, aliases: [String]) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw EngineWordsError.empty }
        guard word.count <= 60 else { throw EngineWordsError.tooLong }
        var seen: Set<String> = [word.lowercased()]
        var out: [String] = []
        for raw in aliases {
            let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.isEmpty || !seen.insert(a.lowercased()).inserted { continue }
            guard a.count <= 60 else { throw EngineWordsError.tooLong }
            out.append(a)
        }
        guard out.count <= 10 else { throw EngineWordsError.tooLong }
        return (word, out)
    }
}

nonisolated struct LiveEngineWords: EngineWordsProviding {
    private static func describe(_ t: ParakeetVocabularyStore.VocabularyConfig.Term) -> [String: Any] { ["text": t.text, "aliases": t.aliases] }

    func list() async -> [[String: Any]] {
        await MainActor.run { ((try? ParakeetVocabularyStore.shared.loadUserBoostTerms()) ?? []).map(Self.describe) }
    }

    func add(text: String, aliases: [String]) async throws -> [String: Any] {
        let clean = try WordRules.clean(text: text, aliases: aliases)
        return try await MainActor.run {
            var terms = (try? ParakeetVocabularyStore.shared.loadUserBoostTerms()) ?? []
            let new = ParakeetVocabularyStore.VocabularyConfig.Term(text: clean.text, weight: 10.0, aliases: clean.aliases)
            if let i = terms.firstIndex(where: { $0.text.lowercased() == clean.text.lowercased() }) { terms[i] = new } else {
                guard terms.count < WordRules.maxWords else { throw EngineWordsError.tooMany }
                terms.insert(new, at: 0)
            }
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(terms)
            return Self.describe(new)
        }
    }

    func delete(text: String) async throws {
        try await MainActor.run {
            var terms = (try? ParakeetVocabularyStore.shared.loadUserBoostTerms()) ?? []
            guard terms.contains(where: { $0.text.lowercased() == text.lowercased() }) else { throw EngineWordsError.notFound }
            terms.removeAll { $0.text.lowercased() == text.lowercased() }
            try ParakeetVocabularyStore.shared.saveUserBoostTerms(terms)
        }
    }

    func export() async throws -> String {
        try await MainActor.run {
            let data = try DictionaryTransferService.shared.encode(try DictionaryTransferService.shared.makeExportDocument())
            return String(decoding: data, as: UTF8.self)
        }
    }

    func importFile(_ json: String, replace: Bool) async throws -> [String: Any] {
        try await MainActor.run {
            let service = DictionaryTransferService.shared
            let document: DictionaryTransferDocument
            do { document = try service.decode(Data(json.utf8)) } catch { throw EngineWordsError.unreadable }
            let summary = try service.restore(document, mode: replace ? .replace : .merge)
            return ["replacements": summary.replacementCount, "words": summary.customWordCount]
        }
    }
}
