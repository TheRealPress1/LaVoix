import Foundation

/// The AI providers (OpenAI, Anthropic, your own server, and so on) and their API keys, for myOS. Keys are write-only: myOS can
/// store or remove one, and can ask whether one is stored, but no operation ever sends a key back. They stay in the Keychain.
/// Plain dictionaries so the socket sends them as JSON; the autotest uses a fake.
nonisolated protocol EngineProvidersProviding: Sendable {
    /// [{id,name,base_url,has_key,local,built_in,selected,model}]
    func list() async -> [[String: Any]]
    /// Stores the key, or removes it when `key` is empty.
    func setKey(id: String, key: String) async throws
    /// Adds a provider of your own (any OpenAI-compatible server). Returns it, without its key.
    func add(name: String, baseURL: String, key: String) async throws -> [String: Any]
    func remove(id: String) async throws
    /// Asks the provider which models it offers, using the stored key.
    func models(id: String) async throws -> [String]
    /// Makes it the provider in use, with `model` when given.
    func select(id: String, model: String?) async throws
}

nonisolated enum EngineProvidersError: LocalizedError, Equatable {
    case unknownProvider, badName, badURL, badKey, builtIn, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unknownProvider: "That provider isn't on your list."
        case .badName: "Give it a name of one to sixty characters."
        case .badURL: "The address must start with http:// or https://."
        case .badKey: "That key is too long or has line breaks in it."
        case .builtIn: "Built-in providers can't be removed; remove their key instead."
        case let .unavailable(m): m
        }
    }
}

nonisolated enum ProviderRules {
    static func name(_ raw: String) throws -> String {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 60 else { throw EngineProvidersError.badName }
        return n
    }

    static func baseURL(_ raw: String) throws -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        guard u.count <= 300, let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw EngineProvidersError.badURL }
        return u
    }

    static func key(_ raw: String) throws -> String {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count <= 400, !k.contains("\n"), !k.contains("\r") else { throw EngineProvidersError.badKey }
        return k
    }
}

nonisolated struct LiveEngineProviders: EngineProvidersProviding {
    @MainActor private static func describe(id: String, name: String, baseURL: String, builtIn: Bool) -> [String: Any] {
        let s = SettingsStore.shared
        let repo = ModelRepository.shared
        let key = repo.providerKey(for: id)
        return [
            "id": id, "name": name, "base_url": baseURL, "built_in": builtIn,
            "has_key": !(s.providerAPIKeys[key] ?? "").isEmpty,
            "local": repo.isLocalEndpoint(baseURL),
            "selected": s.selectedProviderID == id,
            "model": s.selectedModelByProvider[key] ?? "",
        ]
    }

    func list() async -> [[String: Any]] {
        await MainActor.run {
            let repo = ModelRepository.shared
            let builtIns = repo.builtInProvidersList().filter { $0.id != LocalCleanupProvider.providerID }
            var rows = builtIns.map { Self.describe(id: $0.id, name: $0.name, baseURL: repo.defaultBaseURL(for: $0.id), builtIn: true) }
            rows += SettingsStore.shared.savedProviders.map { Self.describe(id: $0.id, name: $0.name, baseURL: $0.baseURL, builtIn: false) }
            return rows
        }
    }

    func setKey(id: String, key: String) async throws {
        let clean = try ProviderRules.key(key)
        try await MainActor.run {
            let s = SettingsStore.shared
            guard ModelRepository.shared.isBuiltIn(id) || s.savedProviders.contains(where: { $0.id == id }) else { throw EngineProvidersError.unknownProvider }
            var keys = s.providerAPIKeys
            let k = ModelRepository.shared.providerKey(for: id)
            if clean.isEmpty { keys.removeValue(forKey: k) } else { keys[k] = clean }
            do { _ = try s.saveProviderAPIKeys(keys) } catch { throw EngineProvidersError.unavailable("macOS wouldn't store the key in the Keychain.") }
        }
    }

    func add(name: String, baseURL: String, key: String) async throws -> [String: Any] {
        let n = try ProviderRules.name(name)
        let u = try ProviderRules.baseURL(baseURL)
        let k = try ProviderRules.key(key)
        let provider = SettingsStore.SavedProvider(name: n, baseURL: u)
        try await MainActor.run {
            let s = SettingsStore.shared
            s.savedProviders = s.savedProviders + [provider]
        }
        if !k.isEmpty { try await self.setKey(id: provider.id, key: k) }
        return await MainActor.run { Self.describe(id: provider.id, name: n, baseURL: u, builtIn: false) }
    }

    func remove(id: String) async throws {
        try await MainActor.run {
            let s = SettingsStore.shared
            guard !ModelRepository.shared.isBuiltIn(id) else { throw EngineProvidersError.builtIn }
            guard s.savedProviders.contains(where: { $0.id == id }) else { throw EngineProvidersError.unknownProvider }
            var keys = s.providerAPIKeys
            for k in ModelRepository.shared.providerKeys(for: id) { keys.removeValue(forKey: k) }
            _ = try? s.saveProviderAPIKeys(keys)
            s.savedProviders = s.savedProviders.filter { $0.id != id }
        }
    }

    func models(id: String) async throws -> [String] {
        let (base, key): (String, String?) = try await MainActor.run {
            let s = SettingsStore.shared
            if let saved = s.savedProviders.first(where: { $0.id == id }) { return (saved.baseURL, s.getAPIKey(for: id)) }
            guard ModelRepository.shared.isBuiltIn(id) else { throw EngineProvidersError.unknownProvider }
            return (ModelRepository.shared.defaultBaseURL(for: id), s.getAPIKey(for: id))
        }
        do { return try await ModelRepository.shared.fetchModels(for: id, baseURL: base, apiKey: key) } catch { throw EngineProvidersError.unavailable(error.localizedDescription) }
    }

    func select(id: String, model: String?) async throws {
        try await MainActor.run {
            let s = SettingsStore.shared
            guard ModelRepository.shared.isBuiltIn(id) || s.savedProviders.contains(where: { $0.id == id }) else { throw EngineProvidersError.unknownProvider }
            s.selectedProviderID = id
            if let model, !model.isEmpty, model.count <= 200 {
                var chosen = s.selectedModelByProvider
                chosen[ModelRepository.shared.providerKey(for: id)] = model
                s.selectedModelByProvider = chosen
            }
        }
    }
}
