import Foundation
import SQLite3

nonisolated struct WhatsAppChat: Identifiable, Equatable {
    let id: Int64
    let name: String
    /// The digits of the number this one-to-one chat is with (WhatsApp finds people by number).
    let phone: String
    let lastText: String
    let lastDate: Date
    let unread: Int
}

/// A new message from someone else, for a card in the notch.
nonisolated struct WhatsAppIncoming: Identifiable, Equatable {
    /// The message's number in WhatsApp's database; later messages have higher numbers.
    let id: Int64
    let chatID: Int64
    let phone: String
    let name: String
    let text: String
    let date: Date
}

nonisolated struct WhatsAppMessage: Identifiable, Equatable {
    let id: Int64
    let text: String
    let date: Date
    let isFromMe: Bool
}

/// Reads WhatsApp Desktop's own database, read-only and in place (it is 80 MB, so it is not copied; nothing is ever written to it). Chats are found by phone
/// number: `14045551234@s.whatsapp.net` is that number, and an anonymous `...@lid` is looked up in WhatsApp's contacts file.
nonisolated enum WhatsAppDatabase {
    private static let container = NSString(string: "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared").expandingTildeInPath
    private static let appleEpoch: TimeInterval = 978_307_200
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func open(_ file: String, in directory: String? = nil) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2((directory ?? self.container) + "/" + file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 600)
        return db
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Anonymous chat id -> phone digits, from WhatsApp's contacts file.
    private static func lidMap(in directory: String? = nil) -> [String: String] {
        guard let db = self.open("ContactsV2.sqlite", in: directory) else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZLID, ZPHONENUMBER FROM ZWAADDRESSBOOKCONTACT WHERE ZLID != '' AND ZPHONENUMBER != ''", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var map: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let digits = self.text(statement, 1).filter(\.isNumber)
            if !digits.isEmpty { map[self.text(statement, 0)] = digits }
        }
        return map
    }

    static func phone(ofJID jid: String, lids: [String: String]) -> String? {
        if let head = jid.components(separatedBy: "@s.whatsapp.net").first, jid.hasSuffix("@s.whatsapp.net") {
            let digits = (head.components(separatedBy: ":").first ?? "").filter(\.isNumber)
            return digits.isEmpty ? nil : digits
        }
        return lids[jid]
    }

    /// The latest one-to-one chats (archived ones left out), newest first, one per number. nil when WhatsApp's database can't be read.
    static func recents(limit: Int = 40) -> [WhatsAppChat]? {
        guard let db = self.open("ChatStorage.sqlite") else { return nil }
        defer { sqlite3_close(db) }
        let lids = self.lidMap()
        // The preview comes from the last message itself: the chat row's own "last text" can hold encoded data for media.
        let sql = """
        SELECT s.Z_PK, s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME, ''), s.ZLASTMESSAGEDATE, COALESCE(m.ZMESSAGETYPE, -1), COALESCE(m.ZTEXT, s.ZLASTMESSAGETEXT, ''), COALESCE(s.ZUNREADCOUNT, 0)
        FROM ZWACHATSESSION s LEFT JOIN ZWAMESSAGE m ON m.Z_PK = s.ZLASTMESSAGE
        WHERE (s.ZCONTACTJID LIKE '%@s.whatsapp.net' OR s.ZCONTACTJID LIKE '%@lid')
          AND COALESCE(s.ZREMOVED, 0) = 0 AND COALESCE(s.ZARCHIVED, 0) = 0 AND COALESCE(s.ZHIDDEN, 0) = 0 AND s.ZLASTMESSAGEDATE IS NOT NULL
        ORDER BY s.ZLASTMESSAGEDATE DESC LIMIT 200
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var seen = Set<String>()
        var out: [WhatsAppChat] = []
        while sqlite3_step(statement) == SQLITE_ROW, out.count < limit {
            guard let phone = self.phone(ofJID: self.text(statement, 1), lids: lids), seen.insert(phone).inserted else { continue }
            let name = self.text(statement, 2).trimmingCharacters(in: .whitespaces)
            out.append(WhatsAppChat(
                id: sqlite3_column_int64(statement, 0),
                name: name.isEmpty ? "+" + phone : name,
                phone: phone,
                lastText: self.preview(code: sqlite3_column_int(statement, 4), text: self.text(statement, 5)),
                lastDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3) + self.appleEpoch),
                unread: Int(sqlite3_column_int(statement, 6))))
        }
        return out
    }

    /// Encoded data (base64 with no spaces) that WhatsApp sometimes keeps where text should be, for media and other non-text messages.
    static func looksEncoded(_ text: String) -> Bool {
        guard text.count >= 24, !text.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The line shown under a chat's name: the text of a text message, the kind of thing for anything else ("Photo", "Voice note").
    static func preview(code: Int32, text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if code <= 0, !body.isEmpty, !self.looksEncoded(body) { return body }
        if code > 0 { return body.isEmpty || self.looksEncoded(body) ? self.kindName(code) : body }
        return self.looksEncoded(body) ? "Attachment" : (body.isEmpty ? "Message" : body)
    }

    /// What a message type is called when it has no text.
    static func kindName(_ code: Int32) -> String {
        switch code {
        case 1: return "Photo"
        case 2: return "Video"
        case 3: return "Voice note"
        case 4: return "Contact"
        case 5: return "Location"
        case 7: return "Link"
        case 8: return "Document"
        case 14: return "Deleted message"
        case 15: return "Sticker"
        default: return "Message"
        }
    }

    /// The newest `limit` messages of the one-to-one chat(s) with this number, oldest first. nil when the database can't be read.
    static func thread(phone: String, limit: Int = 40) -> [WhatsAppMessage]? {
        guard let db = self.open("ChatStorage.sqlite") else { return nil }
        defer { sqlite3_close(db) }
        let lids = self.lidMap()
        var sessions: [Int64] = []
        var sessionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PK, ZCONTACTJID FROM ZWACHATSESSION WHERE ZCONTACTJID LIKE '%@s.whatsapp.net' OR ZCONTACTJID LIKE '%@lid'", -1, &sessionStatement, nil) == SQLITE_OK else { return nil }
        while sqlite3_step(sessionStatement) == SQLITE_ROW {
            if self.phone(ofJID: self.text(sessionStatement, 1), lids: lids) == phone { sessions.append(sqlite3_column_int64(sessionStatement, 0)) }
        }
        sqlite3_finalize(sessionStatement)
        guard !sessions.isEmpty else { return [] }
        let ids = sessions.map(String.init).joined(separator: ",")
        let sql = """
        SELECT Z_PK, ZMESSAGEDATE, ZISFROMME, ZMESSAGETYPE, COALESCE(ZTEXT, '') FROM ZWAMESSAGE
        WHERE ZCHATSESSION IN (\(ids)) AND ZMESSAGETYPE IN (0,1,2,3,4,5,7,8,14,15) AND ZMESSAGEDATE IS NOT NULL
        ORDER BY ZMESSAGEDATE DESC, Z_PK DESC LIMIT ?1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var out: [WhatsAppMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let code = sqlite3_column_int(statement, 3)
            let body = self.text(statement, 4).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(WhatsAppMessage(
                id: sqlite3_column_int64(statement, 0),
                text: code == 0 || (!body.isEmpty && !self.looksEncoded(body)) ? body : self.kindName(code),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1) + self.appleEpoch),
                isFromMe: sqlite3_column_int(statement, 2) != 0))
        }
        return out.reversed()
    }

    // MARK: - New messages (for notch cards)

    /// A message from someone else that is worth a card in the notch.
    struct Raw: Equatable {
        let pk: Int64
        let chatID: Int64
        let jid: String
        let name: String
        let type: Int32
        let text: String
        let date: Date
        /// When the chat's mute ends, in WhatsApp's seconds; 0 when it is not muted. "Always" is a date far in the future.
        let mutedUntil: Double
    }

    /// The message kinds that get a card: text and the things that have a name (photo, voice note, ...). Deleted messages, notices and the like do not.
    private static let alertKinds: Set<Int32> = [0, 1, 2, 3, 4, 5, 7, 8, 15]

    /// From the new messages, the ones to show: one-to-one chats only, not muted, not older than a minute and a half (a backlog arriving after sleep is not
    /// news), and only the latest message of each chat. Pure, so it is tested without a database.
    static func selectAlerts(_ rows: [Raw], lids: [String: String], now: Date = Date(), maxAge: TimeInterval = 90) -> [WhatsAppIncoming] {
        let appleNow = now.timeIntervalSince1970 - self.appleEpoch
        var latest: [Int64: WhatsAppIncoming] = [:]
        for row in rows.sorted(by: { $0.pk < $1.pk }) {
            guard self.alertKinds.contains(row.type), row.mutedUntil <= appleNow, now.timeIntervalSince(row.date) <= maxAge,
                  let phone = self.phone(ofJID: row.jid, lids: lids) else { continue }
            let name = row.name.trimmingCharacters(in: .whitespaces)
            latest[row.chatID] = WhatsAppIncoming(id: row.pk, chatID: row.chatID, phone: phone, name: name.isEmpty ? "+" + phone : name,
                                                  text: self.preview(code: row.type, text: row.text), date: row.date)
        }
        return latest.values.sorted { $0.id < $1.id }
    }

    /// The newest message number in the database (any message), the point to watch from. nil when it can't be read.
    static func latestMessagePK(in directory: String? = nil) -> Int64? {
        guard let db = self.open("ChatStorage.sqlite", in: directory) else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(Z_PK), 0) FROM ZWAMESSAGE", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }

    /// What arrived after message number `pk`: the new highest number, and the messages worth a card. nil when the database can't be read. When nothing is
    /// new it does one tiny query and stops, so watching every few seconds costs almost nothing.
    static func incomingSince(pk: Int64, in directory: String? = nil) -> (newest: Int64, messages: [WhatsAppIncoming])? {
        guard let db = self.open("ChatStorage.sqlite", in: directory) else { return nil }
        defer { sqlite3_close(db) }
        var maxStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(Z_PK), 0) FROM ZWAMESSAGE", -1, &maxStatement, nil) == SQLITE_OK else { return nil }
        let newest = sqlite3_step(maxStatement) == SQLITE_ROW ? sqlite3_column_int64(maxStatement, 0) : 0
        sqlite3_finalize(maxStatement)
        guard newest > pk else { return (max(newest, pk), []) }
        let sql = """
        SELECT m.Z_PK, m.ZCHATSESSION, s.ZCONTACTJID, COALESCE(s.ZPARTNERNAME, ''), m.ZMESSAGETYPE, COALESCE(m.ZTEXT, ''), m.ZMESSAGEDATE, COALESCE(p.ZMUTEDUNTIL, 0)
        FROM ZWAMESSAGE m JOIN ZWACHATSESSION s ON s.Z_PK = m.ZCHATSESSION LEFT JOIN ZWACHATPUSHCONFIG p ON p.ZJID = s.ZCONTACTJID
        WHERE m.Z_PK > ?1 AND m.Z_PK <= ?2 AND m.ZISFROMME = 0 AND m.ZMESSAGEDATE IS NOT NULL
          AND (s.ZCONTACTJID LIKE '%@s.whatsapp.net' OR s.ZCONTACTJID LIKE '%@lid')
        ORDER BY m.Z_PK
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, pk)
        sqlite3_bind_int64(statement, 2, newest)
        var rows: [Raw] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(Raw(pk: sqlite3_column_int64(statement, 0), chatID: sqlite3_column_int64(statement, 1), jid: self.text(statement, 2), name: self.text(statement, 3),
                            type: sqlite3_column_int(statement, 4), text: self.text(statement, 5),
                            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6) + self.appleEpoch), mutedUntil: sqlite3_column_double(statement, 7)))
        }
        return (newest, self.selectAlerts(rows, lids: rows.isEmpty ? [:] : self.lidMap(in: directory)))
    }
}
