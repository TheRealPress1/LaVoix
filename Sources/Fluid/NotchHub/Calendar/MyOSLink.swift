import AppKit
import Foundation

/// Asks myOS to open one of its pages (for example a recorded meeting's notes and transcript), from the notch.
///
/// There is no web address for myOS pages, so the request is a small file in myOS's private folder, next to the engine's socket: `open-request.json`.
/// myOS looks for it about once a second, takes it, brings its window forward and goes to the page. A request older than a minute is ignored, so
/// one left behind while myOS was not running cannot open something later by surprise.
nonisolated enum MyOSLink {
    static let appURL = URL(fileURLWithPath: "/Applications/myOS.app")

    static var requestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("myOS/private/open-request.json", isDirectory: false)
    }

    /// The request as myOS reads it: `{"path":"/meetings","query":"id=<uuid>","requested_at":<unix seconds>}`.
    static func requestBody(path: String, query: String, now: Date = Date()) -> Data {
        let object: [String: Any] = ["path": path, "query": query, "requested_at": Int(now.timeIntervalSince1970)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: self.appURL.path) }

    /// Writes the request and brings myOS forward (starting it when it is not running). Returns false when myOS is not installed.
    @MainActor @discardableResult
    static func open(path: String, query: String, to url: URL? = nil) -> Bool {
        guard self.isInstalled else { return false }
        let target = url ?? self.requestURL
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try self.requestBody(path: path, query: query).write(to: target, options: .atomic)
        } catch {
            DebugLogger.shared.warning("myOS link: could not write the request: \(error.localizedDescription)", source: "Calendar")
            return false
        }
        NSWorkspace.shared.openApplication(at: self.appURL, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// A recorded meeting's notes and transcript, in myOS's Meetings page.
    @MainActor @discardableResult
    static func openMeeting(_ id: UUID) -> Bool {
        self.open(path: "/meetings", query: "id=\(id.uuidString)")
    }
}
