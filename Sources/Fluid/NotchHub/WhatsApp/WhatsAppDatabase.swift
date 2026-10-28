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

    private static func open(_ file: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.container + "/" + file, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return nil }
        sqlite3_busy_timeout(db, 600)
        return db
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Anonymous chat id -> phone digits, from WhatsApp's contacts file.
    private static func lidMap() -> [String: String] {
        guard let db = self.open("ContactsV2.sqlite") else { return [:] }
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
}
