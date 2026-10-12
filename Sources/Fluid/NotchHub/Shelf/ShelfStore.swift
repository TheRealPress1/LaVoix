import AppKit
import Combine
import Foundation

enum NotchShelfSettings {
    private static let enabledKey = "LaVoixNotchShelfEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }
}

/// A temporary holding spot for files. Items are references to the originals, not copies, so nothing is
/// duplicated on disk; an item disappears from the shelf if its file is moved or deleted.
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    struct Item: Identifiable, Codable, Equatable {
        var id: UUID
        var path: String
        var added: Date
        var url: URL { URL(fileURLWithPath: self.path) }
        var name: String { self.url.lastPathComponent }
    }

    @Published private(set) var items: [Item] = []

    private let indexURL: URL

    init(indexURL: URL? = nil) {
        self.indexURL = indexURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaVoix/shelf.json")
        try? FileManager.default.createDirectory(at: self.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.load()
    }

    static func sample() -> ShelfStore {
        let store = ShelfStore(indexURL: FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-shelf-sample-\(UUID().uuidString).json"))
        let now = Date()
        store.items = ["/Applications/Safari.app", "/System/Applications/Notes.app", "/System/Applications/Calendar.app", "/System/Applications/Music.app"]
            .map { Item(id: UUID(), path: $0, added: now) }
        return store
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !self.items.contains(where: { $0.path == url.path }) {
            self.items.insert(Item(id: UUID(), path: url.path, added: Date()), at: 0)
        }
        self.save()
    }

    func remove(_ item: Item) {
        self.items.removeAll { $0.id == item.id }
        self.save()
    }

    func clear() {
        self.items = []
        self.save()
    }

    /// Drops items whose files no longer exist.
    func prune() {
        let kept = self.items.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard kept.count != self.items.count else { return }
        self.items = kept
        self.save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(self.items) else { return }
        try? data.write(to: self.indexURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: self.indexURL),
              let saved = try? JSONDecoder().decode([Item].self, from: data) else { return }
        self.items = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
