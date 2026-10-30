import Foundation

/// Folders System Fix must never trash, whatever the agent proposes. Kept apart from the executor so it can be checked on its own.
nonisolated enum SystemFixProtection {
    /// The on-device language model (2 GB or more, a one-time download) lives in the Hugging Face cache. Dictation cleanup and meeting notes
    /// stop working without it, so "a cache that regenerates" is not a reason to remove it: on 2026-10-30 it was trashed from the storage
    /// fix and meeting notes silently stopped until it was downloaded again.
    static func protectedPaths(home: String) -> [String] {
        let model = "\(home)/.cache/huggingface"
        return [model, URL(fileURLWithPath: model).resolvingSymlinksInPath().path]
    }

    /// True when `path` is a protected folder, lies inside one, or is a folder that contains one (trashing `~/.cache` whole would take the
    /// model with it). Case-insensitive, because the usual Mac volume is.
    static func blocks(_ path: String, home: String) -> Bool {
        let candidate = path.lowercased()
        return self.protectedPaths(home: home).contains { guarded in
            let folder = guarded.lowercased()
            return candidate == folder || candidate.hasPrefix(folder + "/") || folder.hasPrefix(candidate + "/")
        }
    }
}
