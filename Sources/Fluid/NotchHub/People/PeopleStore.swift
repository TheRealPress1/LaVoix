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
        SELECT DISTINCT p.id, p.display_name, s.days_since
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
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(KnownPerson(
                id: String(cString: sqlite3_column_text(statement, 0)),
                name: String(cString: sqlite3_column_text(statement, 1)),
                daysSince: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 2))
            ))
        }
        return out
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
                daysSince: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 3))
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

    static func sample() -> PeopleStore {
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
        store.state = .ready
        return store
    }
}
