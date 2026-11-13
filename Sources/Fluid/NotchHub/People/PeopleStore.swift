import AppKit
import Combine
import Foundation
import SQLite3

/// Who to reach out to, read from myOS's database. LaVoix only reads it (the engine contract: myOS owns the file) and
/// never writes; the scores themselves are computed by myOS.
nonisolated struct PersonNudge: Identifiable, Equatable {
    let id: String
    let name: String
    let circle: Int?
    let daysSince: Int
    let reason: String
}

nonisolated struct PersonRecent: Identifiable, Equatable {
    let id: String
    let name: String
    let daysSince: Int
}

nonisolated struct KnownPerson: Equatable {
    let id: String
    let name: String
    let daysSince: Int?
    /// The invitee address that matched this person (lower case): what finds their picture. nil when it is not known.
    var handle: String? = nil
}

nonisolated enum PeopleDatabase {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/system.db")
    }

    static var isAvailable: Bool { FileManager.default.fileExists(atPath: defaultURL.path) }

    /// The people myOS already knows among these email addresses (matched exactly, case-insensitively). Read-only, in
    /// memory: the addresses are used for the lookup and then forgotten.
    static func known(emails: [String], url: URL = defaultURL) -> [KnownPerson] {
        let wanted = Array(Set(emails.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.contains("@") }))
        guard !wanted.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let marks = wanted.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT DISTINCT p.id, p.display_name, s.days_since, i.value_norm
        FROM identity i JOIN person p ON p.id = i.person_id AND p.merged_into IS NULL
        LEFT JOIN person_score s ON s.person_id = p.id
        WHERE i.kind = 'email' AND i.value_norm IN (\(marks)) ORDER BY COALESCE(s.strength, 0) DESC, p.display_name
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, email) in wanted.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), email, -1, transient) }
        var out: [KnownPerson] = []
        var seen = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            // A person invited under two of their addresses is one person: the first address that matched is the one kept.
            let id = String(cString: sqlite3_column_text(statement, 0))
            guard seen.insert(id).inserted else { continue }
            out.append(KnownPerson(
                id: id,
                name: String(cString: sqlite3_column_text(statement, 1)),
                daysSince: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2)),
                handle: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 3))
            ))
        }
        return out
    }

    /// Where myOS keeps the pictures it found for people (LinkedIn, Gravatar), one file per person: `<person id>.img`.
    static var defaultPhotosDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/photos", isDirectory: true)
    }

    /// The picture myOS keeps for the person behind a phone number or an email, for a conversation whose contact has none of its own. `key` is the handle as the
    /// resolver keys it (an email in lower case, or the last ten digits of a number); `contactID` is the Contacts card's identifier when it is known. The person is
    /// found by the identity myOS holds (the address, the number or the card), never by name, and a person merged into another is followed to the one that has the file.
    static func photoFile(forHandle key: String, contactID: String? = nil, url: URL = defaultURL, photosDirectory: URL = defaultPhotosDirectory) -> URL? {
        var clauses: [String] = []
        var values: [String] = []
        if key.contains("@") {
            clauses.append("(i.kind = 'email' AND i.value_norm = ?)")
            values.append(key.lowercased())
        } else if key.filter(\.isNumber).count >= 7 {
            // Numbers are held in full (+15551230001); the key is their last ten digits, so they are compared at the end.
            clauses.append("(i.kind = 'phone' AND substr(i.value_norm, -\(key.count)) = ?)")
            values.append(key)
        }
        if let contactID, !contactID.isEmpty {
            clauses.append("(i.kind = 'contacts_id' AND i.value_norm = ?)")
            values.append(contactID)
        }
        guard !clauses.isEmpty else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let sql = "SELECT DISTINCT i.person_id, p.merged_into FROM identity i JOIN person p ON p.id = i.person_id WHERE \(clauses.joined(separator: " OR ")) LIMIT 6"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var candidates: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            candidates.append(String(cString: sqlite3_column_text(statement, 0)))
            if sqlite3_column_type(statement, 1) != SQLITE_NULL { candidates.append(String(cString: sqlite3_column_text(statement, 1))) }
        }
        for id in candidates {
            // The file name is the person's id and nothing else: letters, digits and dashes, so no id can point outside the folder.
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { continue }
            let file = photosDirectory.appendingPathComponent("\(id).img", isDirectory: false)
            if FileManager.default.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// email (lowercased) -> the known person it belongs to, for many addresses at once. Read-only, in memory.
    static func emailMap(emails: [String], url: URL = defaultURL) -> [String: KnownPerson] {
        let wanted = Array(Set(emails.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.contains("@") }))
        guard !wanted.isEmpty else { return [:] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let sql = """
        SELECT i.value_norm, p.id, p.display_name, s.days_since
        FROM identity i JOIN person p ON p.id = i.person_id AND p.merged_into IS NULL
        LEFT JOIN person_score s ON s.person_id = p.id WHERE i.kind = 'email'
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return [:] }
        defer { sqlite3_finalize(statement) }
        let wantedSet = Set(wanted)
        var out: [String: KnownPerson] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let email = String(cString: sqlite3_column_text(statement, 0))
            guard wantedSet.contains(email) else { continue }
            out[email] = KnownPerson(
                id: String(cString: sqlite3_column_text(statement, 1)), name: String(cString: sqlite3_column_text(statement, 2)),
                daysSince: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3)),
                handle: email
            )
        }
        return out
    }

    /// nil if the database could not be read (missing, locked, or not yet migrated to the scoring tables).
    static func read(url: URL = defaultURL, now: Date = Date(), nudgeLimit: Int = 5, recentLimit: Int = 5) -> (nudges: [PersonNudge], recent: [PersonRecent])? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let stamp = ISO8601DateFormatter().string(from: now)

        func rows<T>(_ sql: String, _ bind: (OpaquePointer) -> Void, _ map: (OpaquePointer) -> T) -> [T]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return nil }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            var out: [T] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW { out.append(map(statement)); code = sqlite3_step(statement) }
            return code == SQLITE_DONE ? out : nil
        }
        func text(_ s: OpaquePointer, _ c: Int32) -> String { sqlite3_column_text(s, c).map { String(cString: $0) } ?? "" }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        guard let nudges = rows(
            """
            SELECT p.id, p.display_name, s.circle_effective, COALESCE(s.days_since, 0), s.reason
            FROM person_score s JOIN person p ON p.id = s.person_id AND p.merged_into IS NULL
            LEFT JOIN nudge_snooze z ON z.person_id = s.person_id
            WHERE s.urgency > 0 AND (z.until IS NULL OR z.until <= ?1)
            ORDER BY s.urgency DESC, p.display_name COLLATE NOCASE LIMIT ?2
            """,
            { sqlite3_bind_text($0, 1, stamp, -1, transient); sqlite3_bind_int($0, 2, Int32(nudgeLimit)) },
            { PersonNudge(id: text($0, 0), name: text($0, 1), circle: sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int($0, 2)), daysSince: Int(sqlite3_column_int($0, 3)), reason: text($0, 4)) }
        ) else { return nil }
        guard let recent = rows(
            """
            SELECT p.id, p.display_name, COALESCE(s.days_since, 0)
            FROM person_score s JOIN person p ON p.id = s.person_id AND p.merged_into IS NULL
            WHERE s.days_since IS NOT NULL ORDER BY s.days_since ASC, s.strength DESC LIMIT ?1
            """,
            { sqlite3_bind_int($0, 1, Int32(recentLimit)) },
            { PersonRecent(id: text($0, 0), name: text($0, 1), daysSince: Int(sqlite3_column_int($0, 2))) }
        ) else { return nil }
        return (nudges, recent)
    }
}

@MainActor
final class PeopleStore: ObservableObject {
    static let shared = PeopleStore()

    enum State: Equatable { case loading, ready, unavailable }

    @Published private(set) var nudges: [PersonNudge] = []
    @Published private(set) var recent: [PersonRecent] = []
    @Published private(set) var state: State = .loading

    func refresh() {
        Task {
            let result = await Task.detached(priority: .utility) { PeopleDatabase.read() }.value
            if let result {
                self.nudges = result.nudges
                self.recent = result.recent
                self.state = .ready
            } else if self.state == .loading {
                self.state = .unavailable
            }
        }
    }

    func openMyOS() {
        let url = URL(fileURLWithPath: "/Applications/myOS.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `full` gives as many rows as real data does, to check that the tab shows only the ones that fit.
    static func sample(full: Bool = false) -> PeopleStore {
        let store = PeopleStore()
        store.nudges = [
            PersonNudge(id: "1", name: "Maya Chen", circle: 15, daysSince: 28, reason: "28 days since you last spoke · aim for every 14 · they wrote last"),
            PersonNudge(id: "2", name: "Jon Park", circle: 50, daysSince: 85, reason: "85 days since you last spoke · aim for every 30 · you wrote last"),
            PersonNudge(id: "3", name: "Yuri Pereira", circle: 50, daysSince: 62, reason: "62 days since you last spoke · aim for every 30"),
        ]
        store.recent = [
            PersonRecent(id: "4", name: "Krish Bhatia", daysSince: 0),
            PersonRecent(id: "5", name: "Aryan Shah", daysSince: 1),
            PersonRecent(id: "6", name: "Maman", daysSince: 2),
        ]
        if full {
            store.nudges += [PersonNudge(id: "7", name: "Marc Mathieu", circle: 50, daysSince: 70, reason: "70 days since you last spoke · aim for every 30"),
                             PersonNudge(id: "8", name: "Shav Garg", circle: 50, daysSince: 66, reason: "66 days since you last spoke · aim for every 30"),
                             PersonNudge(id: "9", name: "Jojo Seuge", circle: 15, daysSince: 19, reason: "19 days since you last spoke · aim for every 14")]
            store.recent += [PersonRecent(id: "10", name: "Joshua Bell", daysSince: 0), PersonRecent(id: "11", name: "Stino Xanthos", daysSince: 0)]
        }
        store.state = .ready
        return store
    }
}
