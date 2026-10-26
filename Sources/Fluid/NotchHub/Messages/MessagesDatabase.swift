import Foundation
import SQLite3

/// Read-only access to the Messages database (`~/Library/Messages/chat.db`). LaVoix never writes to it.
/// Message text is never logged.
nonisolated final class MessagesDatabase: @unchecked Sendable {
    enum Access: Equatable {
        case granted
        /// macOS is blocking the file: LaVoix needs Full Disk Access.
        case denied
        case missing
    }

    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")

    let url: URL

    init(url: URL = MessagesDatabase.defaultURL) {
        self.url = url
    }

    func checkAccess() -> Access {
        let descriptor = open(self.url.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return (errno == ENOENT) ? .missing : .denied
    }

    // MARK: - Queries

    /// nil when the database couldn't be read (e.g. Messages has it locked for a moment); an empty list means no chats.
    func conversations(limit: Int) -> [MessageConversation]? {
        self.conversationList(limit: limit, chatID: nil)
    }

    /// One chat by its id, shaped like a row of the list (for a chat found by search that is not among the latest).
    func conversation(id: Int64) -> MessageConversation? {
        self.conversationList(limit: 1, chatID: id)?.first
    }

    /// Named group chats whose name contains `text` (a name you gave a group, not the people in it), newest first.
    func groupChats(matching text: String, limit: Int = 5) -> [MessageConversation]? {
        let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let ids = self.query("SELECT ROWID FROM chat WHERE COALESCE(display_name, '') <> '' AND display_name LIKE ?1 ESCAPE '\\' LIMIT 20", bind: {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text($0, 1, pattern, -1, transient)
        }) { sqlite3_column_int64($0, 0) }
        guard let ids else { return nil }
        let found = ids.compactMap { self.conversation(id: $0) }.sorted { $0.lastDate > $1.lastDate }
        return Array(found.prefix(limit))
    }

    private func conversationList(limit: Int, chatID: Int64?) -> [MessageConversation]? {
        let only = chatID.map { "WHERE c.ROWID = \($0)" } ?? ""
        let sql = """
        SELECT c.ROWID, c.guid, COALESCE(c.display_name, ''), COALESCE(c.chat_identifier, ''), COALESCE(c.style, 45),
               m.text, m.attributedBody, m.date, m.is_from_me, COALESCE(m.cache_has_attachments, 0),
               (SELECT COUNT(*) FROM chat_message_join j2 JOIN message m2 ON m2.ROWID = j2.message_id
                 WHERE j2.chat_id = c.ROWID AND m2.is_read = 0 AND m2.is_from_me = 0
                   AND m2.item_type = 0 AND m2.associated_message_type = 0),
               COALESCE((SELECT GROUP_CONCAT(h.id, ',') FROM chat_handle_join chj
                          JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID), '')
        FROM chat c
        JOIN message m ON m.ROWID = (
            SELECT j.message_id FROM chat_message_join j JOIN message mm ON mm.ROWID = j.message_id
             WHERE j.chat_id = c.ROWID AND mm.item_type = 0 AND mm.associated_message_type = 0
             ORDER BY j.message_date DESC LIMIT 1)
        \(only)
        ORDER BY m.date DESC
        LIMIT ?
        """
        return self.query(sql, bind: { sqlite3_bind_int($0, 1, Int32(limit)) }) { row in
            let identifier = Self.string(row, 3)
            let handles = Self.string(row, 11).split(separator: ",").map(String.init)
            let groupName = Self.string(row, 2)
            return MessageConversation(
                id: sqlite3_column_int64(row, 0),
                guid: Self.string(row, 1),
                title: groupName.isEmpty ? (handles.first ?? identifier) : groupName,
                handles: handles.isEmpty ? [identifier] : handles,
                isGroup: sqlite3_column_int(row, 4) == 43,
                lastText: Self.messageText(text: Self.optionalString(row, 5), body: Self.blob(row, 6), hasAttachment: sqlite3_column_int(row, 9) != 0),
                lastDate: Self.date(sqlite3_column_int64(row, 7)),
                lastIsFromMe: sqlite3_column_int(row, 8) != 0,
                unreadCount: Int(sqlite3_column_int(row, 10)),
                hasGroupName: !groupName.isEmpty
            )
        }
    }

    /// The one-to-one chat (never a group) with any of these handles: the one with the newest message when there are several (an iMessage and an
    /// SMS chat with the same person). `[]` when there is none, nil when the database couldn't be read.
    func oneToOneChat(handles: [String]) -> [(id: Int64, guid: String)]? {
        let wanted = handles.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }
        let marks = wanted.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT c.ROWID, c.guid
        FROM chat c
        JOIN chat_handle_join cj ON cj.chat_id = c.ROWID
        JOIN handle h ON h.ROWID = cj.handle_id
        WHERE COALESCE(c.style, 45) = 45 AND h.id IN (\(marks))
          AND (SELECT COUNT(*) FROM chat_handle_join x WHERE x.chat_id = c.ROWID) = 1
        GROUP BY c.ROWID
        ORDER BY (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID) DESC
        """
        return self.query(sql, bind: { stmt in
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, h) in wanted.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), h, -1, transient) }
        }) { row in (id: sqlite3_column_int64(row, 0), guid: Self.string(row, 1)) }
    }

    /// nil when the database couldn't be read right now.
    func messages(chatID: Int64, limit: Int) -> [ThreadMessage]? {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me, COALESCE(m.cache_has_attachments, 0), COALESCE(h.id, '')
        FROM chat_message_join j
        JOIN message m ON m.ROWID = j.message_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE j.chat_id = ? AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.date DESC
        LIMIT ?
        """
        let queried: [ThreadMessage]? = self.query(sql, bind: {
            sqlite3_bind_int64($0, 1, chatID)
            sqlite3_bind_int($0, 2, Int32(limit))
        }) { row in
            ThreadMessage(
                id: sqlite3_column_int64(row, 0),
                text: Self.messageText(text: Self.optionalString(row, 1), body: Self.blob(row, 2), hasAttachment: sqlite3_column_int(row, 5) != 0),
                date: Self.date(sqlite3_column_int64(row, 3)),
                isFromMe: sqlite3_column_int(row, 4) != 0,
                senderHandle: Self.string(row, 6)
            )
        }
        guard let newestFirst = queried else { return nil }
        return newestFirst.reversed()
    }

    /// Messages from other people with a row id above `rowID`, oldest first.
    func incomingMessages(after rowID: Int64) -> [IncomingMessage] {
        let sql = """
        SELECT m.ROWID, c.ROWID, c.guid, COALESCE(c.display_name, ''), COALESCE(c.style, 45), COALESCE(h.id, ''),
               m.text, m.attributedBody, m.date, COALESCE(m.cache_has_attachments, 0)
        FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.ROWID > ? AND m.is_from_me = 0 AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY m.ROWID ASC
        LIMIT 50
        """
        return self.query(sql, bind: { sqlite3_bind_int64($0, 1, rowID) }) { row in
            IncomingMessage(
                rowID: sqlite3_column_int64(row, 0),
                chatID: sqlite3_column_int64(row, 1),
                chatGUID: Self.string(row, 2),
                groupName: Self.string(row, 3),
                isGroup: sqlite3_column_int(row, 4) == 43,
                senderHandle: Self.string(row, 5),
                text: Self.messageText(text: Self.optionalString(row, 6), body: Self.blob(row, 7), hasAttachment: sqlite3_column_int(row, 9) != 0),
                date: Self.date(sqlite3_column_int64(row, 8))
            )
        } ?? []
    }

    /// Who sent each one-to-one message and when, ordered by chat then date. No text column is read: this feeds the
    /// relationship signals shared with myOS, which must never contain message content. nil if the database was busy.
    func activityRows() -> [MessageActivity.Row]? {
        self.query(Self.activitySQL, bind: { _ in }) { row in
            MessageActivity.Row(
                chat: Self.string(row, 0), handle: Self.string(row, 1),
                fromMe: sqlite3_column_int(row, 2) != 0, date: Self.date(sqlite3_column_int64(row, 3))
            )
        }
    }

    /// The same rows as `activityRows`, handed over one at a time instead of collected into a list, so a Mac with half a million
    /// messages never holds them all at once. False if the database couldn't be read (the rows seen so far may be incomplete).
    func streamActivityRows(_ body: (MessageActivity.Row) -> Void) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(self.url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 800)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.activitySQL, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return false
        }
        defer { sqlite3_finalize(statement) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            body(MessageActivity.Row(
                chat: Self.string(statement, 0), handle: Self.string(statement, 1),
                fromMe: sqlite3_column_int(statement, 2) != 0, date: Self.date(sqlite3_column_int64(statement, 3))
            ))
            code = sqlite3_step(statement)
        }
        return code == SQLITE_DONE
    }

    /// Group chats with who is in them and how active they are. Counts and dates only, never text. nil when the database couldn't be read.
    func groupChats() -> [GroupChatsExport.Group]? {
        let count = "(SELECT COUNT(*) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID AND m.item_type = 0 AND m.associated_message_type = 0"
        let sql = """
        SELECT c.guid, COALESCE(c.display_name, ''),
               COALESCE((SELECT GROUP_CONCAT(h.id, ',') FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID), ''),
               \(count)), \(count) AND m.is_from_me = 1),
               (SELECT MAX(m.date) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID)
        FROM chat c WHERE c.style = 43
        """
        return self.query(sql, bind: { _ in }) { row in
            let last = sqlite3_column_int64(row, 5)
            return GroupChatsExport.Group(
                guid: Self.string(row, 0), name: Self.string(row, 1),
                handles: Self.string(row, 2).split(separator: ",").map(String.init),
                total: Int(sqlite3_column_int(row, 3)), fromMe: Int(sqlite3_column_int(row, 4)),
                lastAt: last > 0 ? Self.date(last) : nil
            )
        }
    }

    struct ContentRow {
        let rowid: Int64
        let chat: String
        let handle: String
        let fromMe: Bool
        let date: Date
        let text: String
    }

    private static let contentSelect = """
        SELECT m.ROWID, c.guid,
               COALESCE((SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID LIMIT 1), ''),
               m.is_from_me, m.date, m.text, m.attributedBody, COALESCE(m.cache_has_attachments, 0)
        FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
        WHERE c.style = 45 AND m.item_type = 0 AND m.associated_message_type = 0
        """

    private func contentRow(_ row: OpaquePointer) -> (row: ContentRow, text: () -> String) {
        let rowid = sqlite3_column_int64(row, 0)
        let text = Self.optionalString(row, 5)
        let body = Self.blob(row, 6)
        let attachment = sqlite3_column_int(row, 7) != 0
        let r = ContentRow(rowid: rowid, chat: Self.string(row, 1), handle: Self.string(row, 2), fromMe: sqlite3_column_int(row, 3) != 0,
                           date: Self.date(sqlite3_column_int64(row, 4)), text: "")
        return (r, { Self.messageText(text: text, body: body, hasAttachment: attachment) })
    }

    /// New one-to-one messages after `rowid`, in order, keeping only chats in `keep`. Text is decoded only for kept chats.
    /// `scanned` is the highest ROWID looked at, so progress is saved even when a batch is all skipped.
    func contentRows(after rowid: Int64, limit: Int, keep: Set<String>) -> (rows: [ContentRow], scanned: Int64)? {
        var scanned = rowid
        let rows = self.query(Self.contentSelect + " AND m.ROWID > ?1 ORDER BY m.ROWID LIMIT ?2", bind: {
            sqlite3_bind_int64($0, 1, rowid); sqlite3_bind_int($0, 2, Int32(limit))
        }) { stmt -> ContentRow? in
            let (r, text) = self.contentRow(stmt)
            scanned = max(scanned, r.rowid)
            guard keep.contains(r.chat), !r.handle.isEmpty else { return nil }
            let t = text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return ContentRow(rowid: r.rowid, chat: r.chat, handle: r.handle, fromMe: r.fromMe, date: r.date, text: String(t.prefix(4000)))
        }
        return rows.map { ($0.compactMap { $0 }, scanned) }
    }

    /// Older messages of chats that only now qualify (their ROWIDs are behind the sync cursor).
    func contentRows(chats: [String], upTo rowid: Int64) -> [ContentRow]? {
        guard !chats.isEmpty else { return [] }
        let marks = chats.map { _ in "?" }.joined(separator: ",")
        let rows = self.query(Self.contentSelect + " AND m.ROWID <= ?1 AND c.guid IN (\(marks)) ORDER BY m.ROWID", bind: { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, g) in chats.enumerated() { sqlite3_bind_text(stmt, Int32(i + 2), g, -1, transient) }
        }) { stmt -> ContentRow? in
            let (r, text) = self.contentRow(stmt)
            guard !r.handle.isEmpty else { return nil }
            let t = text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return ContentRow(rowid: r.rowid, chat: r.chat, handle: r.handle, fromMe: r.fromMe, date: r.date, text: String(t.prefix(4000)))
        }
        return rows?.compactMap { $0 }
    }

    /// Metadata only. A test asserts this never mentions a text column.
    static let activitySQL = """
        SELECT c.guid,
               COALESCE((SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
                          WHERE chj.chat_id = c.ROWID LIMIT 1), ''),
               m.is_from_me, m.date
        FROM chat c
        JOIN chat_message_join j ON j.chat_id = c.ROWID
        JOIN message m ON m.ROWID = j.message_id
        WHERE c.style = 45 AND m.item_type = 0 AND m.associated_message_type = 0
        ORDER BY c.ROWID, m.date
        """

    func maxRowID() -> Int64 {
        self.query("SELECT COALESCE(MAX(ROWID), 0) FROM message", bind: { _ in }) { sqlite3_column_int64($0, 0) }?.first ?? 0
    }

    // MARK: - SQLite plumbing

    private func query<T>(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> T) -> [T]? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(self.url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 800)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        var rows: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append(row(statement))
            code = sqlite3_step(statement)
        }
        // Anything but "done" (a lock, an I/O error) means the rows so far may be incomplete, so report a failure
        // instead of a short or empty answer.
        return code == SQLITE_DONE ? rows : nil
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func optionalString(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : self.string(statement, column)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// Messages stores dates as nanoseconds since 2001-01-01 (older systems used seconds).
    static func date(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// The visible text of a message: the `text` column, else the decoded `attributedBody`, else a label.
    static func messageText(text: String?, body: Data?, hasAttachment: Bool) -> String {
        var result = (text?.isEmpty == false ? text : nil) ?? body.flatMap(TypedStreamText.extract(from:)) ?? ""
        // U+FFFC marks where an attachment sits inside the text.
        result = result.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return hasAttachment ? "Attachment" : "" }
        return result
    }
}
