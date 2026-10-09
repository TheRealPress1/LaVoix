import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Identity and model catalog for LaVoix's built-in on-device cleanup provider.
enum LocalCleanupProvider {
    static let providerID = "lavoix-local"
    static let providerName = "On-device (LaVoix)"
    /// Pseudo endpoint so the existing "local endpoints need no API key" rules apply. Never contacted.
    static let pseudoBaseURL = "http://127.0.0.1/lavoix-local"

    struct Model: Identifiable, Hashable {
        let id: String
        let displayName: String
        let detail: String
        let approximateBytes: Int64
    }

    static let models: [Model] = [
        Model(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B",
            detail: "Fast and accurate. Recommended.",
            approximateBytes: 2_280_000_000
        ),
        Model(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            displayName: "Qwen2.5 7B",
            detail: "Higher quality, slower, uses more memory.",
            approximateBytes: 4_300_000_000
        ),
    ]

    static var defaultModelID: String { self.models[0].id }

    static func model(id: String) -> Model? {
        self.models.first { $0.id == id }
    }

    /// Hugging Face's standard cache layout: models--{org}--{name}/snapshots/{rev}/*.safetensors
    static func isDownloaded(modelID: String) -> Bool {
        let folder = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
            .appendingPathComponent(folder)
            .appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else { return false }
        for revision in revisions {
            let dir = snapshots.appendingPathComponent(revision)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if files.contains(where: { $0.hasSuffix(".safetensors") }) { return true }
        }
        return false
    }
}

enum LocalCleanupError: LocalizedError {
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .emptyOutput: return "The on-device model returned no text."
        }
    }
}

/// Runs an open-weights language model in-process with MLX. The model stays resident between
/// dictations for speed and is released after a period of inactivity to give the memory back.
actor LocalCleanupEngine {
    static let shared = LocalCleanupEngine()

    private let idleUnloadSeconds: TimeInterval = 60 * 60

    private var container: ModelContainer?
    private var loadedModelID: String?
    private var loadTask: Task<ModelContainer, Error>?
    private var loadingModelID: String?
    private var idleTask: Task<Void, Never>?

    /// KV caches holding the already-processed cleanup instructions, so each dictation only pays for its own text.
    private var prefixSnapshots: [String: PromptCacheSnapshot] = [:]
    private var prefixOrder: [String] = []
    private let maxPrefixSnapshots = 4
    var usesPrefixCache = true

    func setUsesPrefixCache(_ value: Bool) { self.usesPrefixCache = value }

    var isLoaded: Bool { self.container != nil }

    /// Downloads the model if needed and loads it into memory. Safe to call repeatedly.
    func prepare(modelID: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await self.container(for: modelID, progress: progress)
    }

    /// Loads the model and builds the cache for the standard cleanup prompt, so the first dictation is fast.
    func warm(modelID: String) async {
        guard let container = try? await self.container(for: modelID, progress: nil) else { return }
        _ = await self.prefixSnapshot(container: container, modelID: modelID, system: LocalCleanupPrompt.default)
        self.scheduleIdleUnload()
    }

    /// Cleans `user` according to `system`. Loads the model on first use.
    func generate(
        system: String,
        user: String,
        modelID: String,
        maxTokens: Int = 700
    ) async throws -> String {
        let container = try await self.container(for: modelID, progress: nil)
        self.scheduleIdleUnload()

        let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0.1)
        let raw: String
        if self.usesPrefixCache, let snapshot = await self.prefixSnapshot(container: container, modelID: modelID, system: system) {
            // Each request gets its own copy: a session appends to the cache it is given.
            let copy = PromptCacheSnapshot(
                cache: snapshot.cache.map { $0.copy() },
                metadata: snapshot.metadata,
                state: snapshot.state
            )
            let session = MLXLMCommon.ChatSession(container, promptCache: copy, generateParameters: parameters)
            raw = try await session.respond(to: user)
        } else {
            let session = MLXLMCommon.ChatSession(container, instructions: system, generateParameters: parameters)
            raw = try await session.respond(to: user)
        }
        self.scheduleIdleUnload()

        let cleaned = Self.stripReasoning(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw LocalCleanupError.emptyOutput }
        return cleaned
    }

    func unload() {
        self.idleTask?.cancel()
        self.idleTask = nil
        self.loadTask?.cancel()
        self.loadTask = nil
        self.loadingModelID = nil
        self.container = nil
        self.loadedModelID = nil
        self.prefixSnapshots.removeAll()
        self.prefixOrder.removeAll()
    }

    // MARK: - Private

    /// Processes the instructions (plus one fixed example exchange) once and keeps the resulting cache.
    /// Returns nil if anything goes wrong, in which case the caller falls back to the uncached path.
    private func prefixSnapshot(container: ModelContainer, modelID: String, system: String) async -> PromptCacheSnapshot? {
        let key = modelID + "\u{1F}" + system
        if let existing = self.prefixSnapshots[key] { return existing }
        do {
            let warm = MLXLMCommon.ChatSession(
                container,
                instructions: system,
                generateParameters: GenerateParameters(maxTokens: 96, temperature: 0.1)
            )
            _ = try await warm.respond(to: LocalCleanupPrompt.warmupInput)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lavoix-prefix-\(UUID().uuidString).safetensors")
            defer { try? FileManager.default.removeItem(at: url) }
            try await warm.saveCache(to: url)
            let snapshot = try loadPromptCacheSnapshot(url: url)

            self.prefixSnapshots[key] = snapshot
            self.prefixOrder.append(key)
            while self.prefixOrder.count > self.maxPrefixSnapshots {
                self.prefixSnapshots.removeValue(forKey: self.prefixOrder.removeFirst())
            }
            return snapshot
        } catch {
            return nil
        }
    }

    private func container(
        for modelID: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> ModelContainer {
        if let container, loadedModelID == modelID { return container }

        if let loadTask, loadingModelID == modelID {
            return try await loadTask.value
        }

        // Switching models: drop the old one first so both are never resident together.
        self.container = nil
        self.loadedModelID = nil
        self.loadTask?.cancel()

        let configuration = ModelConfiguration(id: modelID)
        let task = Task<ModelContainer, Error> {
            try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: { value in
                    progress?(value.fractionCompleted)
                }
            )
        }
        self.loadTask = task
        self.loadingModelID = modelID

        do {
            let loaded = try await task.value
            self.container = loaded
            self.loadedModelID = modelID
            self.loadTask = nil
            self.loadingModelID = nil
            return loaded
        } catch {
            self.loadTask = nil
            self.loadingModelID = nil
            throw error
        }
    }

    private func scheduleIdleUnload() {
        self.idleTask?.cancel()
        let delay = self.idleUnloadSeconds
        self.idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Removes `<think>…</think>` blocks that reasoning-style models can emit.
    private static func stripReasoning(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>"), let end = result.range(of: "</think>", range: start.upperBound ..< result.endIndex) {
            result.removeSubrange(start.lowerBound ..< end.upperBound)
        }
        return result
    }
}
