import AppKit
import Foundation

/// What the code allows, whatever the agent proposes. The agent's answer is untrusted input: a plan only reaches the
/// notch after every action passes these checks, and they run again just before anything is done.
nonisolated enum SystemFixSafety {
    /// Apps that are never offered for quitting (the shell around the agent, the system, and this app's own engine).
    static let protectedApps: Set<String> = [
        "finder", "dock", "systemuiserver", "loginwindow", "windowserver", "controlcenter", "notificationcenter",
        "myos", "myos engine", "lavoix", "fluid", "activity monitor", "system settings",
    ]

    /// Folders whose contents the agent may propose trashing (each item inside, never the folder itself).
    private static func allowedParents(home: String) -> [String] {
        [
            "\(home)/Library/Caches", "\(home)/Library/Logs", "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport", "\(home)/Library/Developer/CoreSimulator/Caches",
            "\(home)/.cache", "\(home)/Library/Application Support/myOS/old-builds", "\(home)/Downloads",
        ]
    }

    /// Dedicated cache folders that may be trashed whole.
    private static func allowedWhole(home: String) -> [String] {
        ["\(home)/.npm/_cacache", "\(home)/.cache", "\(home)/Library/pnpm", "\(home)/Library/Developer/Xcode/DerivedData"]
    }

    /// Returns the resolved URL when `path` may be trashed, else nil. Symlinks are resolved first so a link inside
    /// Caches that points at Documents is refused.
    static func trashableURL(_ path: String) -> URL? {
        let home = NSHomeDirectory()
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let resolved = url.path
        let parents = self.allowedParents(home: home).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        // DerivedData folders inside projects are fine too: they are build output by definition.
        let isDerivedData = url.lastPathComponent == "DerivedData" && resolved.hasPrefix(home + "/") && !resolved.contains("/Library/")
        let inside = parents.contains { resolved.hasPrefix($0 + "/") }
        let whole = self.allowedWhole(home: home).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.contains(resolved)
        guard inside || whole || isDerivedData else { return nil }
        return url
    }

    /// `resource` decides what kind of action can help: quitting frees memory and CPU, trashing files frees storage.
    static func sanitize(_ plan: SystemFixPlan, for resource: SystemResource) throws -> SystemFixPlan {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let footprints = Dictionary(
            SystemStatsSampler.readTopApps(limit: 80).map { ($0.name.lowercased(), $0.bytes) },
            uniquingKeysWith: max
        )
        var seen = Set<String>()
        var clean: [SystemFixAction] = []
        for var action in plan.actions.prefix(8) {
            guard action.kind == (resource == .storage ? .trashPath : .quitApp) else { continue }
            switch action.kind {
            case .quitApp:
                guard let app = Self.runningApp(named: action.target, in: running) else { continue }
                let name = app.localizedName ?? action.target
                action.target = name
                action.bytes = footprints[name.lowercased()]
            case .trashPath:
                guard let url = Self.trashableURL(action.target) else { continue }
                action.target = url.path
                action.bytes = Self.allocatedSize(of: url)
            }
            if seen.insert(action.id).inserted { clean.append(action) }
        }
        return SystemFixPlan(summary: plan.summary, actions: clean)
    }

    static func runningApp(named name: String, in apps: [NSRunningApplication]? = nil) -> NSRunningApplication? {
        let apps = apps ?? NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let wanted = name.lowercased()
        guard !self.protectedApps.contains(wanted) else { return nil }
        let match = apps.first {
            let names = [$0.localizedName, $0.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0?.lowercased() }
            return names.contains(wanted)
        }
        guard let match, match.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let names = [match.localizedName, match.bundleURL?.deletingPathExtension().lastPathComponent].compactMap { $0?.lowercased() }
        return names.contains(where: self.protectedApps.contains) ? nil : match
    }

    /// Disk space the item really holds (allocated blocks), summed through folders.
    static func allocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var total: UInt64 = 0
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true {
            return UInt64(values.totalFileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

nonisolated struct SystemFixReport: Equatable, Sendable {
    var quitAsked: [String] = []
    var trashed: [String] = []
    var trashedBytes: UInt64 = 0
    var skipped: [String] = []
    var trashEmptied: Bool?
}

enum SystemFixExecutor {
    /// Does the approved actions. Apps are asked to quit politely (an app with unsaved work can still ask the user);
    /// files go to the Trash, never straight to deletion, and the report says the space is only freed once it is emptied.
    @MainActor
    static func run(_ actions: [SystemFixAction]) async -> SystemFixReport {
        var report = SystemFixReport()
        for action in actions {
            switch action.kind {
            case .quitApp:
                if let app = SystemFixSafety.runningApp(named: action.target), app.terminate() {
                    report.quitAsked.append(action.label)
                } else {
                    report.skipped.append(action.label)
                }
            case .trashPath:
                guard let url = SystemFixSafety.trashableURL(action.target) else { report.skipped.append(action.label); continue }
                let moved = await Task.detached(priority: .utility) { () -> Bool in
                    (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
                }.value
                if moved {
                    report.trashed.append(action.label)
                    report.trashedBytes += action.bytes ?? 0
                } else {
                    report.skipped.append(action.label)
                }
            }
        }
        return report
    }

    /// Where Finder is asked to empty the Trash. Never the main thread: Finder only answers once the Trash really is empty, and on a busy Mac with a
    /// big Trash that took half a minute or more. Waiting for it on the main thread (as this once did) stops the whole engine for that long: no
    /// dictation, no notch, and the freeze watchdog restarts it (2026-10-30, 38 s).
    private static let trashQueue = DispatchQueue(label: "com.myos.systemfix.empty-trash", qos: .utility)

    /// Asks Finder to empty the Trash (the first time macOS asks whether this app may control Finder). Returns when Finder has answered.
    nonisolated static func emptyTrash() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.trashQueue.async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil)
            }
        }
    }
}
