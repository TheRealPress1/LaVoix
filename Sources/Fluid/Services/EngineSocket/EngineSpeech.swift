import Foundation

/// Speech recognition models for myOS: which ones are installed, which one is in use, and download, switch and delete. The
/// actions start the same work as the Voice Engine page in LaVoix and return at once; myOS asks again to follow the progress.
nonisolated protocol EngineSpeechProviding: Sendable {
    func list() async -> [String: Any]
    func activate(id: String) async throws
    func download(id: String) async throws
    func cancelDownload() async throws
    func delete(id: String) async throws
}

nonisolated enum EngineSpeechError: LocalizedError, Equatable {
    case unknownModel, busy, notInstalled, activeModel, nothingToCancel
    var errorDescription: String? {
        switch self {
        case .unknownModel: "That speech model does not exist."
        case .busy: "Dictation, a recording or another model task is running. Try again when it finishes."
        case .notInstalled: "Download that model first."
        case .activeModel: "That is the model in use. Switch to another one before deleting it."
        case .nothingToCancel: "No download is running."
        }
    }
}

nonisolated struct LiveEngineSpeech: EngineSpeechProviding {
    @MainActor private static var model: VoiceEngineSettingsViewModel {
        VoiceEngineSettingsViewModel(settings: SettingsStore.shared, appServices: AppServices.shared)
    }

    @MainActor private static func find(_ id: String) throws -> SettingsStore.SpeechModel {
        guard let m = SettingsStore.SpeechModel.availableModels.first(where: { $0.id == id }) else { throw EngineSpeechError.unknownModel }
        return m
    }

    func list() async -> [String: Any] {
        await MainActor.run {
            let vm = Self.model
            vm.installations.refresh()
            let models: [[String: Any]] = SettingsStore.SpeechModel.availableModels.map { m in
                [
                    "id": m.id, "name": m.humanReadableName, "brand": m.brandName, "language": m.languageSupport,
                    "size": vm.speechModelDownloadSize(m), "installed": vm.isSpeechModelInstalled(m), "active": vm.isActiveSpeechModel(m),
                    "update_available": vm.isSpeechModelUpdateAvailable(m), "accuracy": Int(m.accuracyPercent), "speed": Int(m.speedPercent),
                    "description": m.cardDescription,
                ]
            }
            var out: [String: Any] = ["models": models, "blocked": vm.areSpeechModelActionsBlocked]
            if let downloading = vm.downloadingModel {
                out["downloading"] = ["id": downloading.id, "progress": vm.downloadProgress, "cancelling": vm.isCancellingModelDownload] as [String: Any]
            }
            if vm.asr.showError { out["error"] = vm.asr.errorMessage }
            return out
        }
    }

    func activate(id: String) async throws {
        try await MainActor.run {
            let m = try Self.find(id)
            let vm = Self.model
            guard !vm.areSpeechModelActionsBlocked else { throw EngineSpeechError.busy }
            guard vm.isSpeechModelInstalled(m) else { throw EngineSpeechError.notInstalled }
            vm.activateSpeechModel(m)
        }
    }

    func download(id: String) async throws {
        try await MainActor.run {
            let m = try Self.find(id)
            let vm = Self.model
            guard !vm.areSpeechModelActionsBlocked else { throw EngineSpeechError.busy }
            vm.downloadSpeechModel(m)
        }
    }

    func cancelDownload() async throws {
        try await MainActor.run {
            let vm = Self.model
            guard vm.downloadingModel != nil else { throw EngineSpeechError.nothingToCancel }
            vm.cancelSpeechModelDownload()
        }
    }

    func delete(id: String) async throws {
        try await MainActor.run {
            let m = try Self.find(id)
            let vm = Self.model
            guard !vm.isActiveSpeechModel(m) else { throw EngineSpeechError.activeModel }
            guard !vm.areSpeechModelActionsBlocked else { throw EngineSpeechError.busy }
            vm.deleteSpeechModel(m)
        }
    }
}
