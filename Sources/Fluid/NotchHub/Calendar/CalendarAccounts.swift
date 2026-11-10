import AppKit
import Contacts
import Foundation
import SQLite3

/// Who the new-event form says you are: the headshot on your "Me" card in Contacts, and the address each of your calendars belongs to.
/// Everything is read on this Mac and kept in memory; nothing is written or sent anywhere.
nonisolated enum CalendarOwner {
    /// Calendar's own database. Reading it needs the Full Disk Access the engine already has; without it the picker simply shows calendar names.
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
    }

    /// The column of Calendar's `Calendar` table that holds the owner's address: the known name first, else any column with "email" in its name.
    static func emailColumn(in columns: [String]) -> String? {
        if let exact = columns.first(where: { $0.lowercased() == "owner_identity_email" }) { return exact }
        return columns.first { $0.lowercased().contains("email") }
    }

    /// calendarIdentifier -> the owner's address, for the calendars that have one. Empty when the database cannot be read. `summary` is for the
    /// log (column names and how many calendars have an address), never the addresses themselves.
    static func ownerEmails(url: URL = CalendarOwner.databaseURL) -> (emails: [String: String], summary: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return ([:], "Calendar's database could not be opened")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)

        func rows(_ sql: String, columns: Int32) -> [[String]]? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return nil }
            defer { sqlite3_finalize(statement) }
            var out: [[String]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                out.append((0..<columns).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
            }
            return out
        }

        guard let info = rows("PRAGMA table_info(Calendar)", columns: 2) else { return ([:], "Calendar's database has no Calendar table") }
        let columns = info.compactMap { $0.count > 1 ? $0[1] : nil }
        guard let emailColumn = self.emailColumn(in: columns), let idColumn = columns.first(where: { $0.lowercased() == "uuid" }) else {
            return ([:], "Calendar's table has no owner address column (columns: \(columns.joined(separator: ",")))")
        }
        let sql = "SELECT \"\(idColumn)\", \"\(emailColumn)\" FROM Calendar WHERE \"\(emailColumn)\" IS NOT NULL AND \"\(emailColumn)\" != ''"
        guard let found = rows(sql, columns: 2) else { return ([:], "the owner address query failed") }
        var out: [String: String] = [:]
        for row in found {
            let email = row[1].replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive]).trimmingCharacters(in: .whitespaces).lowercased()
            if email.contains("@") { out[row[0]] = email }
        }
        return (out, "\(out.count) of the calendars have an owner address (column \(emailColumn))")
    }

    /// The photo on your "Me" card (thumbnail bytes) and your initials, or nil when there is no card or no permission.
    static func me() -> (thumbnail: Data?, initials: String)? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ]
        guard let card = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return nil }
        let initials = [card.givenName, card.familyName].compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return (card.thumbnailImageData, initials)
    }

    /// Initials for a name or an address: "Gaspard Seugé" -> "GS", "geneva@x.com" -> "G".
    static func initials(for text: String) -> String {
        let name = text.split(separator: "@").first.map(String.init) ?? text
        let letters = name.split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.joined()
    }
}

/// One place a new event can be saved, as the account picker shows it.
nonisolated struct CalendarSaveTarget: Identifiable, Equatable {
    let id: String
    let calendarTitle: String
    /// The account the calendar lives in (iCloud, Google, an address, ...).
    let accountTitle: String
    /// The address the calendar belongs to, when it is known.
    let email: String?

    /// What names this target in the list: the address when there is one, else the calendar's name.
    var primary: String { self.email ?? self.calendarTitle }
    var secondary: String { self.email == nil ? self.accountTitle : "\(self.calendarTitle) · \(self.accountTitle)" }
}
