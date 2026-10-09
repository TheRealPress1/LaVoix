import Combine
import Foundation
import SwiftUI

/// Thread-safe, UserDefaults-backed switches read from the dictation pipeline.
enum LocalCleanupSettings {
    private static let enabledKey = "LaVoixLocalCleanupEnabled"
    private static let modelKey = "LaVoixLocalCleanupModelID"

    nonisolated static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    nonisolated static var modelID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: self.modelKey) ?? ""
            return LocalCleanupProvider.model(id: stored) != nil ? stored : LocalCleanupProvider.defaultModelID
        }
        set { UserDefaults.standard.set(newValue, forKey: self.modelKey) }
    }
}

/// Drives the on-device cleanup settings card: download, enable, and a quick test.
@MainActor
final class LocalCleanupController: ObservableObject {
    static let shared = LocalCleanupController()

    enum Status: Equatable {
        case notDownloaded
        case downloading(Double?)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var status: Status = .notDownloaded
    @Published private(set) var isEnabled = LocalCleanupSettings.isEnabled
    @Published var modelID = LocalCleanupSettings.modelID
    @Published private(set) var testOutput: String?
    @Published private(set) var testSeconds: Double?
    @Published private(set) var isTesting = false

    private var prepareTask: Task<Void, Never>?

    private init() {
        self.refreshStatus()
    }

    var selectedModel: LocalCleanupProvider.Model {
        LocalCleanupProvider.model(id: self.modelID) ?? LocalCleanupProvider.models[0]
    }

    func refreshStatus() {
        if case .downloading = self.status { return }
        if case .loading = self.status { return }
        self.status = LocalCleanupProvider.isDownloaded(modelID: self.modelID) ? .ready : .notDownloaded
    }

    func selectModel(_ id: String) {
        guard id != self.modelID, !self.isBusy else { return }
        self.modelID = id
        LocalCleanupSettings.modelID = id
        self.status = LocalCleanupProvider.isDownloaded(modelID: id) ? .ready : .notDownloaded
        Task { await LocalCleanupEngine.shared.unload() }
        if self.isEnabled, self.status == .notDownloaded { self.prepare() }
    }

    var isBusy: Bool {
        switch self.status {
        case .downloading, .loading: return true
        default: return false
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            self.isEnabled = true
            LocalCleanupSettings.isEnabled = true
            // Make sure dictation actually runs cleanup (setup leaves it off).
            if SettingsStore.shared.dictationPromptSelection(for: .primary) == .off {
                SettingsStore.shared.setDictationPromptSelection(.default)
            }
            if self.status != .ready { self.prepare() } else { self.warmUp() }
        } else {
            self.isEnabled = false
            LocalCleanupSettings.isEnabled = false
            self.prepareTask?.cancel()
            Task { await LocalCleanupEngine.shared.unload() }
            self.refreshStatus()
        }
    }

    /// Downloads (if needed) and loads the selected model.
    func prepare() {
        guard self.prepareTask == nil else { return }
        let id = self.modelID
        let alreadyDownloaded = LocalCleanupProvider.isDownloaded(modelID: id)
        self.status = alreadyDownloaded ? .loading : .downloading(nil)
        self.prepareTask = Task { [weak self] in
            do {
                try await LocalCleanupEngine.shared.prepare(modelID: id) { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(fraction)
                    }
                }
                self?.status = .ready
                self?.warmUp()
            } catch is CancellationError {
                self?.refreshStatus()
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
            self?.prepareTask = nil
        }
    }

    private func warmUp() {
        guard self.status == .ready else { return }
        let id = self.modelID
        Task { await LocalCleanupEngine.shared.warm(modelID: id) }
    }

    /// Called at launch: if cleanup is on and the model is on disk, load it in the background.
    func warmUpIfEnabled() {
        guard self.isEnabled, LocalCleanupProvider.isDownloaded(modelID: self.modelID) else { return }
        self.status = .ready
        self.warmUp()
    }

    func runTest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !self.isTesting, self.status == .ready else { return }
        self.isTesting = true
        self.testOutput = nil
        self.testSeconds = nil
        let started = Date()
        let id = self.modelID
        Task { [weak self] in
            let prompt = SettingsStore.shared.effectiveDictationSystemPrompt(for: .primary, appBundleID: nil)
            let request = DictationPromptRequest(promptText: prompt, transcript: trimmed)
            do {
                let output = try await LocalCleanupEngine.shared.generate(
                    system: LocalCleanupPrompt.resolve(appPrompt: request.systemPrompt),
                    user: request.userContent,
                    modelID: id
                )
                self?.testOutput = output
            } catch {
                self?.testOutput = "Error: \(error.localizedDescription)"
            }
            self?.testSeconds = Date().timeIntervalSince(started)
            self?.isTesting = false
        }
    }
}
