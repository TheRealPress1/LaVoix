import AppKit
import Combine
import Foundation
import SQLite3

/// Someone you can FaceTime: a name from myOS's people, and the one phone number or email to call (a number when there is one).
nonisolated struct FaceTimeContact: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
}

nonisolated enum FaceTimeDatabase {
    /// People who have a phone number or an email, matching `query` in their name when it isn't empty, the people you are closest to
    /// first. Read-only: LaVoix never writes myOS's file. nil when the file can't be read.
    static func read(query: String, limit: Int = 30, url: URL = PeopleDatabase.defaultURL) -> [FaceTimeContact]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let sql = """
        SELECT p.id, p.display_name,
               COALESCE((SELECT value_norm FROM identity WHERE person_id = p.id AND kind = 'phone' ORDER BY created LIMIT 1),
                        (SELECT value_norm FROM identity WHERE person_id = p.id AND kind = 'email' ORDER BY created LIMIT 1)) AS address
        FROM person p LEFT JOIN person_score s ON s.person_id = p.id
        WHERE p.merged_into IS NULL AND address IS NOT NULL AND p.display_name LIKE ?1 ESCAPE '\\'
        ORDER BY COALESCE(s.strength, 0) DESC, p.display_name COLLATE NOCASE LIMIT ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, Self.pattern(for: query), -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var out: [FaceTimeContact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1), let address = sqlite3_column_text(statement, 2) else { continue }
            out.append(FaceTimeContact(id: String(cString: id), name: String(cString: name), address: String(cString: address)))
        }
        return out
    }

    /// "ma" -> "%ma%", with LIKE's own characters taken literally.
    static func pattern(for query: String) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%" + text + "%"
    }

    /// The address that starts the call: facetime:// for video, facetime-audio:// for audio. A number keeps its +, an email its @.
    static func callURL(address: String, audio: Bool) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var allowed = CharacterSet.urlHostAllowed
        allowed.insert(charactersIn: "+@")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: (audio ? "facetime-audio://" : "facetime://") + encoded)
    }
}

@MainActor
final class FaceTimeStore: ObservableObject {
    static let shared = FaceTimeStore()

    enum State: Equatable { case loading, ready, unavailable }

    @Published private(set) var contacts: [FaceTimeContact] = []
    @Published private(set) var state: State = .loading
    private var latest = 0

    func search(_ query: String) {
        self.latest += 1
        let ticket = self.latest
        Task {
            let result = await Task.detached(priority: .userInitiated) { FaceTimeDatabase.read(query: query) }.value
            // A slower, older search never replaces a newer one.
            guard ticket == self.latest else { return }
            if let result {
                self.contacts = result
                self.state = .ready
            } else {
                self.state = .unavailable
            }
        }
    }

    func call(_ contact: FaceTimeContact, audio: Bool) {
        guard let url = FaceTimeDatabase.callURL(address: contact.address, audio: audio) else { return }
        NSWorkspace.shared.open(url)
    }

    func openFaceTime() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
