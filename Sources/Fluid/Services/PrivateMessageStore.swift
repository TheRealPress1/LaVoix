import Foundation
import SQLite3

/// Message text kept for myOS, on this Mac only. It lives in `~/Library/Application Support/myOS/private/messages.db`,
/// deliberately NOT in the myOS data folder (which iCloud syncs), with owner-only permissions. LaVoix writes it; myOS
/// reads it. Only chats that qualify as real conversations are kept (which also leaves out 2FA codes and business
/// texts), excluded handles are never stored (and are deleted if added later), and turning the setting off deletes the file.
nonisolated enum PrivateMessageStore {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/private/messages.db")
    }

    struct Result: Equatable {
        var added: Int
        var total: Int
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS message (
      rowid   INTEGER PRIMARY KEY,   -- the Messages database's own ROWID, so a message is never stored twice
      chat    TEXT NOT NULL,
      handle  TEXT NOT NULL,
      from_me INTEGER NOT NULL,
      sent_at TEXT NOT NULL,
      text    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_message_handle ON message(handle, sent_at);
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
    """

    private static func open(_ url: URL) -> OpaquePointer? {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return db
    }

    private static func meta(_ db: OpaquePointer, _ key: String) -> String? {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1", -1, &s, nil) == SQLITE_OK, let s else { return nil }
        sqlite3_bind_text(s, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_text(s, 0).map { String(cString: $0) } : nil
    }

    private static func setMeta(_ db: OpaquePointer, _ key: String, _ value: String) {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value", -1, &s, nil) == SQLITE_OK, let s else { return }
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(s, 1, key, -1, t); sqlite3_bind_text(s, 2, value, -1, t)
        sqlite3_step(s)
    }

    private static func count(_ db: OpaquePointer) -> Int {
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM message", -1, &s, nil) == SQLITE_OK, let s, sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(s, 0))
    }

    private static func insert(_ db: OpaquePointer, _ rows: [MessagesDatabase.ContentRow]) -> Int {
        guard !rows.isEmpty else { return 0 }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var added = 0
        var ins: OpaquePointer?, fts: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO message (rowid, chat, handle, from_me, sent_at, text) VALUES (?1,?2,?3,?4,?5,?6)", -1, &ins, nil)
        sqlite3_prepare_v2(db, "INSERT INTO message_fts (rowid, text) VALUES (?1, ?2)", -1, &fts, nil)
        let t = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let iso = ISO8601DateFormatter()
        for r in rows {
            sqlite3_reset(ins); sqlite3_clear_bindings(ins)
            sqlite3_bind_int64(ins, 1, r.rowid); sqlite3_bind_text(ins, 2, r.chat, -1, t); sqlite3_bind_text(ins, 3, r.handle, -1, t)
            sqlite3_bind_int(ins, 4, r.fromMe ? 1 : 0); sqlite3_bind_text(ins, 5, iso.string(from: r.date), -1, t); sqlite3_bind_text(ins, 6, r.text, -1, t)
            guard sqlite3_step(ins) == SQLITE_DONE, sqlite3_changes(db) > 0 else { continue }
            sqlite3_reset(fts); sqlite3_clear_bindings(fts)
            sqlite3_bind_int64(fts, 1, r.rowid); sqlite3_bind_text(fts, 2, r.text, -1, t)
            sqlite3_step(fts)
            added += 1
        }
        sqlite3_finalize(ins); sqlite3_finalize(fts)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return added
    }

    /// Removes every stored message from the given handles (normalised as for the exclusion list).
    @discardableResult
    static func applyExclusions(_ db: OpaquePointer, excluded: Set<String>) -> Int {
        guard !excluded.isEmpty else { return 0 }
        var s: OpaquePointer?
        defer { sqlite3_finalize(s) }
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT handle FROM message", -1, &s, nil) == SQLITE_OK, let s else { return 0 }
        var doomed: [String] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let h = String(cString: sqlite3_column_text(s, 0))
            if excluded.contains(MessageActivity.normalizedForExclusion(h)) { doomed.append(h) }
        }
        for h in doomed {
            sqlite3_exec(db, "DELETE FROM message_fts WHERE rowid IN (SELECT rowid FROM message WHERE handle = '\(h.replacingOccurrences(of: "'", with: "''"))')", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM message WHERE handle = '\(h.replacingOccurrences(of: "'", with: "''"))'", nil, nil, nil)
        }
        return doomed.count
    }

    /// Brings the store up to date: newly qualifying chats are back-filled, then everything after the cursor is read.
    @discardableResult
    static func sync(reader: MessagesDatabase, qualified: Set<String>, excluded: Set<String>, url: URL = defaultURL) -> Result? {
        guard let db = open(url) else { return nil }
        defer { sqlite3_close(db) }
        applyExclusions(db, excluded: excluded)
        let cursor = Int64(meta(db, "cursor") ?? "0") ?? 0
        let known = Set((meta(db, "qualified")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
        var added = 0
        // Chats that qualify now but did not before have older messages behind the cursor.
        let fresh = qualified.subtracting(known).sorted()
        if cursor > 0, !fresh.isEmpty {
            for start in stride(from: 0, to: fresh.count, by: 400) {
                guard let rows = reader.contentRows(chats: Array(fresh[start..<min(start + 400, fresh.count)]), upTo: cursor) else { return nil }
                added += insert(db, rows.filter { !excluded.contains(MessageActivity.normalizedForExclusion($0.handle)) })
            }
        }
        var position = cursor
        while true {
            guard let batch = reader.contentRows(after: position, limit: 20000, keep: qualified) else { return nil }
            added += insert(db, batch.rows.filter { !excluded.contains(MessageActivity.normalizedForExclusion($0.handle)) })
            guard batch.scanned > position else { break }
            position = batch.scanned
            setMeta(db, "cursor", String(position))
        }
        setMeta(db, "qualified", String(data: (try? JSONEncoder().encode(qualified.sorted())) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
        return Result(added: added, total: count(db))
    }

    /// Deletes the store and its journal files. Used when the setting is turned off.
    static func purge(url: URL = defaultURL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }
}
