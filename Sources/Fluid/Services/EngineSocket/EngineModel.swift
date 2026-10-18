import Foundation

/// The on-device language model that cleans up dictation and writes meeting notes: which one, whether it is downloaded, and turning
/// it on. Cloud providers and their keys are deliberately not here. Plain dictionaries so the socket sends them as JSON.
nonisolated protocol EngineModelProviding: Sendable {
    /// {enabled, selected, state: not_downloaded|downloading|loading|ready|failed, progress?, error?, models:[{id,name,detail,bytes,downloaded}]}
    func status() async -> [String: Any]
    func setEnabled(_ enabled: Bool) async
    func select(id: String) async throws
    /// Starts the download (and loading) and returns; ask `status` for progress.
    func download() async
}

nonisolated enum EngineModelError: LocalizedError, Equatable {
    case unknownModel, busy
    var errorDescription: String? {
        switch self {
        case .unknownModel: "That model isn't on the list."
        case .busy: "Wait for the current download or load to finish."
        }
    }
}

nonisolated struct LiveEngineModel: EngineModelProviding {
    func status() async -> [String: Any] {
        await MainActor.run {
            let c = LocalCleanupController.shared
            c.refreshStatus()
            var out: [String: Any] = ["enabled": c.isEnabled, "selected": c.modelID]
            switch c.status {
            case .notDownloaded: out["state"] = "not_downloaded"
            case let .downloading(fraction): out["state"] = "downloading"; if let fraction { out["progress"] = fraction }
            case .loading: out["state"] = "loading"
            case .ready: out["state"] = "ready"
            case let .failed(message): out["state"] = "failed"; out["error"] = message
            }
            out["models"] = LocalCleanupProvider.models.map {
                ["id": $0.id, "name": $0.displayName, "detail": $0.detail, "bytes": $0.approximateBytes, "downloaded": LocalCleanupProvider.isDownloaded(modelID: $0.id)] as [String: Any]
            }
            return out
        }
    }

    func setEnabled(_ enabled: Bool) async {
        await MainActor.run { LocalCleanupController.shared.setEnabled(enabled) }
    }

    func select(id: String) async throws {
        try await MainActor.run {
            guard LocalCleanupProvider.model(id: id) != nil else { throw EngineModelError.unknownModel }
            guard !LocalCleanupController.shared.isBusy else { throw EngineModelError.busy }
            LocalCleanupController.shared.selectModel(id)
        }
    }

    func download() async {
        await MainActor.run { LocalCleanupController.shared.prepare() }
    }
}
