import AppKit
import Combine
import Foundation

/// The quick-links shelf in the notch: things you paste all the time, one click to copy. The list is a small file myOS keeps; you can
/// add or remove entries here in the notch or in myOS Settings. Each change rereads the file first and replaces it in one step, and
/// myOS merges what was added here when it saves, so neither side overwrites the other.
@MainActor
final class QuickLinksStore: ObservableObject {
    static let shared = QuickLinksStore()

    struct Link: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
    }

    @Published private(set) var links: [Link] = []
    @Published private(set) var copiedID: String?

    private var lastModified: Date?
    private var copiedTask: Task<Void, Never>?

    nonisolated static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/quick-links.json")
    }

    /// The links in a file's bytes, in order. A file that isn't ours, or an entry without a name or text, gives nothing for that entry.
    nonisolated static func parse(_ data: Data) -> [Link] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let rows = root["links"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return rows.prefix(40).compactMap { row in
            guard let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                  let value = (row["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { return nil }
            var id = (row["id"] as? String) ?? label
            while !seen.insert(id).inserted { id += "x" }
            return Link(id: id, label: String(label.prefix(60)), value: String(value.prefix(2000)))
        }
    }

    /// Reads the file again only when it changed.
    func reload() {
        let url = Self.fileURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard modified != self.lastModified || self.links.isEmpty else { return }
        self.lastModified = modified
        guard let data = try? Data(contentsOf: url) else { self.links = []; return }
        self.links = Self.parse(data)
    }

    enum EditError: LocalizedError {
        case needName, needText, tooLong, full
        var errorDescription: String? {
            switch self {
            case .needName: "Give it a name."
            case .needText: "Paste or type what should be copied."
            case .tooLong: "That is too long to keep (60 characters for the name, 2000 for the text)."
            case .full: "You can keep up to 40 quick links."
            }
        }
    }

    /// The file's contents after adding one entry, or why it can't be added. Pure, so it can be tested.
    nonisolated static func adding(label rawLabel: String, value rawValue: String, to links: [Link], id: String = "n" + UUID().uuidString.prefix(8).lowercased()) throws -> [Link] {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw EditError.needName }
        guard !value.isEmpty else { throw EditError.needText }
        guard label.count <= 60, value.count <= 2000 else { throw EditError.tooLong }
        guard links.count < 40 else { throw EditError.full }
        var newID = id
        while links.contains(where: { $0.id == newID }) { newID += "x" }
        return links + [Link(id: newID, label: label, value: value)]
    }

    nonisolated static func encode(_ links: [Link]) throws -> Data {
        let rows = links.map { ["id": $0.id, "label": $0.label, "value": $0.value] }
        return try JSONSerialization.data(withJSONObject: ["links": rows], options: [.prettyPrinted, .sortedKeys])
    }

    /// Rereads the file, applies the change, and replaces the file in one step.
    private func change(_ edit: ([Link]) throws -> [Link]) throws {
        let url = Self.fileURL
        let current = (try? Data(contentsOf: url)).map(Self.parse) ?? []
        let updated = try edit(current)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = url.deletingLastPathComponent().appendingPathComponent("quick-links.json.tmp")
        try Self.encode(updated).write(to: staging, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        self.lastModified = nil
        self.reload()
    }

    func add(label: String, value: String) throws {
        try self.change { try Self.adding(label: label, value: value, to: $0) }
    }

    func remove(_ link: Link) {
        try? self.change { $0.filter { $0.id != link.id } }
    }

    func copy(_ link: Link) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.value, forType: .string)
        self.copiedID = link.id
        self.copiedTask?.cancel()
        self.copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { self?.copiedID = nil }
        }
    }
}
