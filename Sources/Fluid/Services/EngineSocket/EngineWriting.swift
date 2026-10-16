import ApplicationServices
import Foundation

/// What myOS can ask the engine about Recent Writing. The text lives in LaVoix's own store (0600, outside any synced folder)
/// and only travels over the owner-only engine socket to the myOS window. Plain dictionaries so the socket sends them as JSON.
nonisolated protocol EngineWritingProviding: Sendable {
    func list(search: String, limit: Int) async -> [[String: Any]]
    func versions(entryID: Int64) async -> [[String: Any]]
    func delete(entryID: Int64) async
    /// Deletes everything, or only what one app wrote.
    func deleteAll(bundleID: String?) async
    func settings() async -> [String: Any]
    /// Applies any of `enabled`, `days`, `excluded` that are present.
    func updateSettings(_ changes: [String: Any]) async
}

nonisolated struct LiveEngineWriting: EngineWritingProviding {
    var store: WritingRecoveryStore = .shared

    func list(search: String, limit: Int) async -> [[String: Any]] {
        self.store.entries(search: search, limit: min(max(limit, 1), 500)).map { e in
            [
                "id": e.id, "bundle_id": e.bundleID, "app_name": e.appName, "window_title": e.windowTitle,
                "first_at": e.firstAt.timeIntervalSince1970, "last_at": e.lastAt.timeIntervalSince1970,
                "latest": e.latest, "peak": e.peak, "version_count": e.versionCount,
            ]
        }
    }

    func versions(entryID: Int64) async -> [[String: Any]] {
        self.store.versions(entryID: entryID).map { ["id": $0.id, "at": $0.at.timeIntervalSince1970, "text": $0.text] }
    }

    func delete(entryID: Int64) async { self.store.delete(entryID: entryID) }

    func deleteAll(bundleID: String?) async { self.store.deleteAll(bundleID: bundleID) }

    func settings() async -> [String: Any] {
        [
            "enabled": WritingRecoverySettings.isEnabled,
            "days": WritingRecoverySettings.retentionDays,
            "excluded": WritingRecoverySettings.excludedBundles,
            "accessibility": AXIsProcessTrusted(),
            "count": self.store.count(),
        ]
    }

    func updateSettings(_ changes: [String: Any]) async {
        if let enabled = changes["enabled"] as? Bool {
            WritingRecoverySettings.isEnabled = enabled
            WritingRecoveryMonitor.shared.apply()
        }
        if let days = changes["days"] as? Int, [7, 14, 30].contains(days) {
            WritingRecoverySettings.retentionDays = days
            _ = self.store.purge(olderThanDays: days)
        }
        if let excluded = changes["excluded"] as? [String] {
            WritingRecoverySettings.excludedBundles = excluded
        }
    }
}
