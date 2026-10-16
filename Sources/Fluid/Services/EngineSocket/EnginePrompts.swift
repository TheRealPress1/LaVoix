import Foundation

/// Cleanup styles for myOS: the named instructions the AI follows when it tidies a dictation (mode "dictate") or edits
/// selected text (mode "edit"), and which one is active. Per-app rules and per-style shortcuts or models stay in LaVoix for
/// now. Plain dictionaries so the socket sends them as JSON.
nonisolated protocol EnginePromptsProviding: Sendable {
    func list() async -> [String: Any]
    func save(id: String?, name: String, prompt: String, mode: String, includeContext: Bool) async throws -> [String: Any]
    func delete(id: String) async throws
    /// `selection` is "default", "off" or "profile:<id>".
    func select(mode: String, selection: String) async throws
    /// An empty `text` puts the built-in prompt back.
    func setDefault(mode: String, text: String) async throws
}

nonisolated enum EnginePromptsError: LocalizedError, Equatable {
    case badName, badPrompt, badMode, notFound, badSelection
    var errorDescription: String? {
        switch self {
        case .badName: "Give the style a name of one to sixty characters."
        case .badPrompt: "The instructions can be up to 8,000 characters."
        case .badMode: "The mode must be dictate or edit."
        case .notFound: "That style no longer exists."
        case .badSelection: "That is not a style for this mode."
        }
    }
}

/// The checks, apart from the store so they can be tested on their own.
nonisolated enum PromptRules {
    static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw EnginePromptsError.badName }
        return name
    }

    static func cleanPrompt(_ raw: String) throws -> String {
        guard raw.count <= 8000 else { throw EnginePromptsError.badPrompt }
        return raw
    }

    static func mode(_ raw: String) throws -> SettingsStore.PromptMode {
        switch raw {
        case "dictate": return .dictate
        case "edit": return .edit
        default: throw EnginePromptsError.badMode
        }
    }

    /// Splits "profile:<id>" and friends.
    static func parse(selection: String) throws -> (kind: String, id: String?) {
        if selection == "default" || selection == "off" { return (selection, nil) }
        if selection.hasPrefix("profile:"), selection.count > 8 { return ("profile", String(selection.dropFirst(8))) }
        throw EnginePromptsError.badSelection
    }
}

nonisolated struct LiveEnginePrompts: EnginePromptsProviding {
    private static func name(_ mode: SettingsStore.PromptMode) -> String { mode.normalized == .dictate ? "dictate" : "edit" }

    private static func describe(_ p: SettingsStore.DictationPromptProfile) -> [String: Any] {
        ["id": p.id, "name": p.name, "mode": Self.name(p.mode), "prompt": SettingsStore.customPromptBody(p.prompt, mode: p.mode), "include_context": p.includeContext]
    }

    @MainActor private static func selection(_ s: SettingsStore, _ mode: SettingsStore.PromptMode) -> String {
        if mode == .dictate {
            switch s.dictationPromptSelection {
            case .off: return "off"
            case let .profile(id): return "profile:\(id)"
            case .default, .privateAI: return "default"
            }
        }
        if s.isEditPromptOff { return "off" }
        return s.selectedEditPromptID.map { "profile:\($0)" } ?? "default"
    }

    @MainActor private static func defaults(_ s: SettingsStore, _ mode: SettingsStore.PromptMode) -> [String: Any] {
        let override = s.defaultPromptOverride(for: mode)
        let text = override.map { SettingsStore.stripBasePrompt(for: mode, from: $0) } ?? SettingsStore.defaultPromptBodyText(for: mode)
        return ["selected": Self.selection(s, mode), "default_prompt": text, "default_is_custom": override != nil]
    }

    func list() async -> [String: Any] {
        await MainActor.run {
            let s = SettingsStore.shared
            return ["profiles": s.dictationPromptProfiles.map(Self.describe), "dictate": Self.defaults(s, .dictate), "edit": Self.defaults(s, .edit)]
        }
    }

    func save(id: String?, name: String, prompt: String, mode rawMode: String, includeContext: Bool) async throws -> [String: Any] {
        let clean = try PromptRules.cleanName(name)
        let body = try PromptRules.cleanPrompt(prompt)
        let mode = try PromptRules.mode(rawMode)
        return try await MainActor.run {
            let s = SettingsStore.shared
            var profiles = s.dictationPromptProfiles
            let now = Date()
            let saved: SettingsStore.DictationPromptProfile
            if let id {
                guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw EnginePromptsError.notFound }
                var updated = profiles[index]
                let previousMode = updated.mode
                updated.name = clean
                updated.prompt = SettingsStore.customPromptBody(body, mode: mode)
                updated.usesLegacyEmptyPromptFallback = false
                updated.mode = mode
                updated.includeContext = mode == .edit ? true : includeContext
                updated.updatedAt = now
                profiles[index] = updated
                saved = updated
                if previousMode.normalized != mode, s.selectedPromptID(for: previousMode) == id { s.setSelectedPromptID(nil, for: previousMode) }
            } else {
                saved = SettingsStore.DictationPromptProfile(name: clean, prompt: SettingsStore.customPromptBody(body, mode: mode), mode: mode, includeContext: mode == .edit ? true : includeContext, createdAt: now, updatedAt: now)
                profiles.append(saved)
            }
            s.dictationPromptProfiles = profiles
            s.reconcilePromptStateAfterProfileChanges()
            return Self.describe(s.dictationPromptProfiles.first { $0.id == saved.id } ?? saved)
        }
    }

    func delete(id: String) async throws {
        try await MainActor.run {
            let s = SettingsStore.shared
            guard let doomed = s.dictationPromptProfiles.first(where: { $0.id == id }) else { throw EnginePromptsError.notFound }
            s.dictationPromptProfiles = s.dictationPromptProfiles.filter { $0.id != id }
            s.reconcilePromptStateAfterProfileChanges()
            if s.selectedPromptID(for: doomed.mode) == id { s.setSelectedPromptID(nil, for: doomed.mode) }
            NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        }
    }

    func select(mode rawMode: String, selection: String) async throws {
        let mode = try PromptRules.mode(rawMode)
        let (kind, id) = try PromptRules.parse(selection: selection)
        try await MainActor.run {
            let s = SettingsStore.shared
            switch kind {
            case "off":
                if mode == .dictate { s.setDictationPromptSelection(.off) } else { s.isEditPromptOff = true }
            case "default":
                s.setSelectedPromptID(nil, for: mode)
            default:
                guard let id, s.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == mode }) else { throw EnginePromptsError.badSelection }
                s.setSelectedPromptID(id, for: mode)
            }
            NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        }
    }

    func setDefault(mode rawMode: String, text: String) async throws {
        let mode = try PromptRules.mode(rawMode)
        let body = try PromptRules.cleanPrompt(text)
        await MainActor.run {
            let s = SettingsStore.shared
            s.setDefaultPromptOverride(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : SettingsStore.stripBasePrompt(for: mode, from: body), for: mode)
        }
    }
}
