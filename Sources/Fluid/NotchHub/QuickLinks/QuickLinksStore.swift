import AppKit
import Combine
import Foundation

/// The quick-links shelf in the notch: things you paste all the time, one click to copy. myOS owns the list (the engine contract:
/// myOS writes the file, LaVoix only reads it), so edits are made in myOS and show up here within a few seconds.
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
