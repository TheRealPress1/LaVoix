import Foundation
import SQLite3

/// What the monitor saw in one text field at one moment.
nonisolated struct WritingSnapshot: Sendable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    /// Identity of the field within the running app (pid + element), so successive snapshots of one field become one entry.
    var fieldKey: String
    var text: String
    var at: Date
}

nonisolated struct WritingEntry: Identifiable, Equatable, Sendable {
    var id: Int64
    var bundleID: String
    var appName: String
    var windowTitle: String
    var firstAt: Date
    var lastAt: Date
    var latest: String
    /// The longest text this field ever held: what survives if the draft was selected and deleted.
    var peak: String
    var versionCount: Int

    var hasLongerDraft: Bool { self.peak.count > Int(Double(self.latest.count) * 1.2) + 10 }
}

nonisolated struct WritingVersion: Identifiable, Equatable, Sendable {
    var id: Int64
    var at: Date
    var text: String
}

/// Text you were writing, kept on this Mac so a lost draft can be copied back. Local-only SQLite (0600) under
/// Application Support, never in an iCloud folder. One entry per text field; the entry keeps the latest text, the longest
/// text, and a thinned history. Password-looking fields are filtered before anything reaches here (`WritingFilter`).
nonisolated final class WritingRecoveryStore: @unchecked Sendable {
    static let shared = WritingRecoveryStore(url: WritingRecoveryStore.defaultURL)

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LaVoix/WritingRecovery/writing.db")
    }

    /// Below this a field is not worth keeping (names, search terms, one-line answers).
    static let minimumLength = 40
    /// A field that reappears (page re-rendered) within this long, with the same start, is the same draft.
    static let mergeWindow: TimeInterval = 30 * 60
    static let maxStoredCharacters = 100_000
    static let maxVersionsPerEntry = 30

    enum Outcome: Equatable { case created, updated, unchanged, tooShort, tooLong }

    private let queue = DispatchQueue(label: "lavoix.writing-store")
    private var db: OpaquePointer?

    init(url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        guard sqlite3_open_v2(url.path, &self.db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            self.db = nil
            return
        }
        sqlite3_busy_timeout(self.db, 2000)
        self.exec("PRAGMA journal_mode = WAL;")
        self.exec("""
        CREATE TABLE IF NOT EXISTS entry (
          id INTEGER PRIMARY KEY AUTOINCREMENT, field_key TEXT NOT NULL, bundle TEXT NOT NULL, app TEXT NOT NULL, window TEXT NOT NULL,
          first_at REAL NOT NULL, last_at REAL NOT NULL, latest TEXT NOT NULL, peak TEXT NOT NULL, version_count INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS idx_entry_last ON entry(last_at DESC);
        CREATE INDEX IF NOT EXISTS idx_entry_field ON entry(field_key, last_at DESC);
        CREATE TABLE IF NOT EXISTS version (
          id INTEGER PRIMARY KEY AUTOINCREMENT, entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE, at REAL NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS idx_version_entry ON version(entry_id, at);
        CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(latest, peak, window, app, tokenize = 'unicode61 remove_diacritics 2');
        PRAGMA foreign_keys = ON;
        """)
        self.exec("PRAGMA foreign_keys = ON;")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    deinit { sqlite3_close(self.db) }

    // MARK: Writing

    @discardableResult
    func ingest(_ s: WritingSnapshot) -> Outcome {
        self.queue.sync {
            guard self.db != nil else { return .unchanged }
            let text = s.text
            if text.count > Self.maxStoredCharacters { return .tooLong }
            let now = s.at.timeIntervalSince1970

            guard let entry = self.findEntry(for: s, now: now) else {
                if text.count < Self.minimumLength { return .tooShort }
                self.exec("BEGIN;")
                let id = self.insertEntry(s)
                self.addVersion(entryID: id, at: now, text: text)
                self.exec("COMMIT;")
                return .created
            }
            if entry.latest == text { return .unchanged }

            self.exec("BEGIN;")
            // A big drop (selected-all and deleted, or the field was cleared): make sure the text we are about to
            // overwrite is a stored version, not just the latest value.
            let lastVersionText = self.lastVersionText(entryID: entry.id)
            let dropped = entry.latest.count >= Self.minimumLength && text.count * 2 < entry.latest.count
            if dropped, lastVersionText != entry.latest { self.addVersion(entryID: entry.id, at: entry.lastAt.timeIntervalSince1970, text: entry.latest) }
            let peak = text.count >= entry.peak.count ? text : entry.peak
            self.run("UPDATE entry SET latest = ?1, peak = ?2, last_at = ?3, field_key = ?4, window = ?5 WHERE id = ?6",
                     [.text(text), .text(peak), .double(now), .text(s.fieldKey), .text(s.windowTitle.isEmpty ? entry.windowTitle : s.windowTitle), .int(entry.id)])
            // Periodic versions as the text grows or changes a lot.
            let reference = lastVersionText ?? ""
            let delta = abs(text.count - reference.count)
            if delta >= 20 || (!reference.isEmpty && Double(delta) >= Double(reference.count) * 0.1) || dropped {
                if lastVersionText != text { self.addVersion(entryID: entry.id, at: now, text: text) }
            }
            self.thinVersions(entryID: entry.id)
            self.refreshIndex(id: entry.id)
            self.exec("COMMIT;")
            return .updated
        }
    }

    // MARK: Reading

    func entries(search: String = "", limit: Int = 200) -> [WritingEntry] {
        self.queue.sync {
            guard self.db != nil else { return [] }
            let term = Self.ftsQuery(search)
            let sql: String
            var binds: [Bind] = []
            if let term {
                sql = "SELECT e.id, e.bundle, e.app, e.window, e.first_at, e.last_at, e.latest, e.peak, e.version_count FROM entry e WHERE e.id IN (SELECT rowid FROM entry_fts WHERE entry_fts MATCH ?1) ORDER BY e.last_at DESC LIMIT ?2"
                binds = [.text(term), .int(Int64(limit))]
            } else {
                sql = "SELECT id, bundle, app, window, first_at, last_at, latest, peak, version_count FROM entry ORDER BY last_at DESC LIMIT ?1"
                binds = [.int(Int64(limit))]
            }
            return self.query(sql, binds) { Self.entry(from: $0) }
        }
    }

    func versions(entryID: Int64) -> [WritingVersion] {
        self.queue.sync {
            self.query("SELECT id, at, text FROM version WHERE entry_id = ?1 ORDER BY at DESC", [.int(entryID)]) {
                WritingVersion(id: sqlite3_column_int64($0, 0), at: Date(timeIntervalSince1970: sqlite3_column_double($0, 1)), text: Self.string($0, 2))
            }
        }
    }

    func count() -> Int {
        self.queue.sync { self.query("SELECT COUNT(*) FROM entry", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    // MARK: Removing

    func delete(entryID: Int64) {
        self.queue.sync {
            self.exec("BEGIN;")
            self.run("DELETE FROM entry_fts WHERE rowid = ?1", [.int(entryID)])
            self.run("DELETE FROM version WHERE entry_id = ?1", [.int(entryID)])
            self.run("DELETE FROM entry WHERE id = ?1", [.int(entryID)])
            self.exec("COMMIT;")
        }
    }

    func deleteAll(bundleID: String? = nil) {
        self.queue.sync {
            self.exec("BEGIN;")
            let filter = bundleID == nil ? "" : " WHERE bundle = ?1"
            let binds: [Bind] = bundleID.map { [.text($0)] } ?? []
            self.run("DELETE FROM entry_fts WHERE rowid IN (SELECT id FROM entry\(filter))", binds)
            self.run("DELETE FROM version WHERE entry_id IN (SELECT id FROM entry\(filter))", binds)
            self.run("DELETE FROM entry\(filter)", binds)
            self.exec("COMMIT;")
            if bundleID == nil { self.exec("VACUUM;") }
        }
    }

    /// Drops entries not touched for `days` days. Returns how many.
    @discardableResult
    func purge(olderThanDays days: Int, now: Date = Date()) -> Int {
        self.queue.sync {
            let cutoff = now.timeIntervalSince1970 - Double(days) * 86400
            let doomed = self.query("SELECT id FROM entry WHERE last_at < ?1", [.double(cutoff)]) { sqlite3_column_int64($0, 0) }
            guard !doomed.isEmpty else { return 0 }
            self.exec("BEGIN;")
            self.run("DELETE FROM entry_fts WHERE rowid IN (SELECT id FROM entry WHERE last_at < ?1)", [.double(cutoff)])
            self.run("DELETE FROM version WHERE entry_id IN (SELECT id FROM entry WHERE last_at < ?1)", [.double(cutoff)])
            self.run("DELETE FROM entry WHERE last_at < ?1", [.double(cutoff)])
            self.exec("COMMIT;")
            return doomed.count
        }
    }

    // MARK: Internals

    private func findEntry(for s: WritingSnapshot, now: Double) -> WritingEntry? {
        let recent = now - Self.mergeWindow
        if let same = self.query(Self.selectEntry + " WHERE field_key = ?1 AND last_at >= ?2 ORDER BY last_at DESC LIMIT 1", [.text(s.fieldKey), .double(recent)], { Self.entry(from: $0) }).first {
            return same
        }
        // The page may have re-created the field: same app and window, recently, and one text begins like the other.
        let candidates = self.query(Self.selectEntry + " WHERE bundle = ?1 AND window = ?2 AND last_at >= ?3 ORDER BY last_at DESC LIMIT 5",
                                    [.text(s.bundleID), .text(s.windowTitle), .double(recent)]) { Self.entry(from: $0) }
        let head = String(s.text.prefix(40))
        return candidates.first { c in
            guard head.count >= 12 || c.peak.count >= 12 else { return false }
            return c.peak.hasPrefix(String(head.prefix(min(head.count, 40)))) || s.text.hasPrefix(String(c.peak.prefix(40))) || c.latest.hasPrefix(head)
        }
    }

    private static let selectEntry = "SELECT id, bundle, app, window, first_at, last_at, latest, peak, version_count FROM entry"

    private func insertEntry(_ s: WritingSnapshot) -> Int64 {
        let now = s.at.timeIntervalSince1970
        self.run("INSERT INTO entry (field_key, bundle, app, window, first_at, last_at, latest, peak, version_count) VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?6, 0)",
                 [.text(s.fieldKey), .text(s.bundleID), .text(s.appName), .text(s.windowTitle), .double(now), .text(s.text)])
        let id = sqlite3_last_insert_rowid(self.db)
        self.refreshIndex(id: id)
        return id
    }

    private func addVersion(entryID: Int64, at: Double, text: String) {
        self.run("INSERT INTO version (entry_id, at, text) VALUES (?1, ?2, ?3)", [.int(entryID), .double(at), .text(text)])
        self.run("UPDATE entry SET version_count = (SELECT COUNT(*) FROM version WHERE entry_id = ?1) WHERE id = ?1", [.int(entryID)])
    }

    private func lastVersionText(entryID: Int64) -> String? {
        self.query("SELECT text FROM version WHERE entry_id = ?1 ORDER BY at DESC, id DESC LIMIT 1", [.int(entryID)]) { Self.string($0, 0) }.first
    }

    /// Keeps the first version, the longest one and the most recent ones; drops the oldest of the rest.
    private func thinVersions(entryID: Int64) {
        let count = self.query("SELECT COUNT(*) FROM version WHERE entry_id = ?1", [.int(entryID)]) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        guard count > Self.maxVersionsPerEntry else { return }
        self.run("""
        DELETE FROM version WHERE id IN (
          SELECT id FROM version WHERE entry_id = ?1
            AND id != (SELECT MIN(id) FROM version WHERE entry_id = ?1)
            AND id != (SELECT id FROM version WHERE entry_id = ?1 ORDER BY LENGTH(text) DESC, id DESC LIMIT 1)
          ORDER BY at ASC, id ASC LIMIT ?2)
        """, [.int(entryID), .int(Int64(count - Self.maxVersionsPerEntry))])
        self.run("UPDATE entry SET version_count = (SELECT COUNT(*) FROM version WHERE entry_id = ?1) WHERE id = ?1", [.int(entryID)])
    }

    private func refreshIndex(id: Int64) {
        self.run("DELETE FROM entry_fts WHERE rowid = ?1", [.int(id)])
        self.run("INSERT INTO entry_fts (rowid, latest, peak, window, app) SELECT id, latest, peak, window, app FROM entry WHERE id = ?1", [.int(id)])
    }

    /// Words from user input, quoted, ANDed, last one as a prefix: never a syntax error.
    static func ftsQuery(_ input: String) -> String? {
        let words = input.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " ")
    }

    private static func entry(from stmt: OpaquePointer) -> WritingEntry {
        WritingEntry(
            id: sqlite3_column_int64(stmt, 0), bundleID: string(stmt, 1), appName: string(stmt, 2), windowTitle: string(stmt, 3),
            firstAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)), lastAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            latest: string(stmt, 6), peak: string(stmt, 7), versionCount: Int(sqlite3_column_int64(stmt, 8))
        )
    }

    private static func string(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private enum Bind { case text(String), double(Double), int(Int64) }

    private func exec(_ sql: String) { sqlite3_exec(self.db, sql, nil, nil, nil) }

    private func prepare(_ sql: String, _ binds: [Bind]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { sqlite3_finalize(stmt); return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, bind) in binds.enumerated() {
            let index = Int32(i + 1)
            switch bind {
            case let .text(t): sqlite3_bind_text(stmt, index, t, -1, transient)
            case let .double(d): sqlite3_bind_double(stmt, index, d)
            case let .int(n): sqlite3_bind_int64(stmt, index, n)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Bind]) {
        guard let stmt = self.prepare(sql, binds) else { return }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func query<T>(_ sql: String, _ binds: [Bind], _ row: (OpaquePointer) -> T) -> [T] {
        guard let stmt = self.prepare(sql, binds) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }
}
