import CryptoKit
import Foundation

/// Who is in which group chat, for the people map in myOS: names, members, how active. Never message text. It is written to
/// `~/Library/Application Support/myOS/private/groups.json` (owner-only, outside the iCloud-synced myOS folder), like the private
/// message store, and only while Messages sharing is on.
nonisolated enum GroupChatsExport {
    struct Group: Equatable {
        let guid: String
        let name: String
        /// The other people in the chat (not you), as Messages names them: phone numbers and emails.
        let handles: [String]
        let total: Int
        let fromMe: Int
        let lastAt: Date?
    }

    /// Chats of 2 to 40 other people. Fewer is a one-to-one chat; more is a broadcast list that says nothing about who knows whom.
    static let minOthers = 2
    static let maxOthers = 40

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/private/groups.json")
    }

    /// The groups to share: members with a usable identity (an email, or 7+ digits), minus anyone you excluded, tidied and sorted.
    static func prepare(_ groups: [Group], excluded: Set<String>) -> [Group] {
        groups.compactMap { g in
            var seen = Set<String>()
            let handles = g.handles.filter { h in
                MessageActivity.hintKind(for: h) != nil && !excluded.contains(MessageActivity.normalizedForExclusion(h)) && seen.insert(h.lowercased()).inserted
            }
            guard handles.count >= minOthers, handles.count <= maxOthers else { return nil }
            return Group(guid: g.guid, name: g.name.trimmingCharacters(in: .whitespacesAndNewlines), handles: handles.sorted(), total: g.total, fromMe: g.fromMe, lastAt: g.lastAt)
        }
        .sorted { ($0.lastAt ?? .distantPast, $0.guid) > ($1.lastAt ?? .distantPast, $1.guid) }
    }

    /// A stable id that doesn't reveal the chat's own identifier.
    static func id(for guid: String) -> String {
        SHA256.hash(data: Data(guid.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ groups: [Group], now: Date) throws -> Data {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = groups.map { g in
            var row: [String: Any] = ["id": id(for: g.guid), "name": g.name, "handles": g.handles, "total": g.total, "from_me": g.fromMe]
            if let last = g.lastAt { row["last_at"] = iso.string(from: last) }
            return row
        }
        return try JSONSerialization.data(withJSONObject: ["generated_at": iso.string(from: now), "groups": rows], options: [.sortedKeys])
    }

    /// Replaces the file in one step, owner-only.
    @discardableResult
    static func write(_ groups: [Group], now: Date = Date(), url: URL = defaultURL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".groups.json.tmp")
        try encode(groups, now: now).write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        return url
    }

    static func purge(url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
