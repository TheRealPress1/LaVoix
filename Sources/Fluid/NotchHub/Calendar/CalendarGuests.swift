import Contacts
import Foundation
import SQLite3

/// Someone to invite to a new event.
nonisolated struct CalendarGuest: Identifiable, Equatable, Hashable {
    let name: String
    let email: String

    var id: String { self.email }
    /// What to show for them: their name when there is one, else the address.
    var display: String { self.name.isEmpty || self.name.lowercased() == self.email ? self.email : self.name }
    var initials: String { CalendarOwner.initials(for: self.display) }
}

/// Finding people to invite: the people myOS already knows (their names and addresses, ordered by how close you are) and your Contacts, searched
/// as you type, plus an address typed out in full. Read-only and in memory.
nonisolated enum CalendarGuestDirectory {
    /// Addresses that are never a person.
    private static let automated = ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "notifications@", "notification@"]

    /// A plausible address: one @, something before it, a dot in the domain, no spaces.
    static func looksLikeEmail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(" "), t.filter({ $0 == "@" }).count == 1, let at = t.firstIndex(of: "@") else { return false }
        let local = t[..<at]
        let domain = t[t.index(after: at)...]
        guard !local.isEmpty, let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) < domain.endIndex
    }

    static func isAutomated(_ email: String) -> Bool {
        let lower = email.lowercased()
        return self.automated.contains { lower.contains($0) }
    }

    /// The words typed (lowercase, at most three, without the characters SQL's LIKE treats specially).
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.filter { $0 != "%" && $0 != "_" && $0 != "\\" } }
            .filter { !$0.isEmpty }
            .prefix(3).map { String($0) }
    }

    /// The lists joined in order, one entry per address, without anyone in `excluding` and without automated senders.
    static func merge(_ lists: [[CalendarGuest]], excluding: Set<String>, limit: Int) -> [CalendarGuest] {
        var seen = excluding.map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }
        var out: [CalendarGuest] = []
        for guest in lists.joined() {
            let key = guest.email.lowercased()
            guard !self.isAutomated(key), seen.insert(key).inserted else { continue }
            out.append(CalendarGuest(name: guest.name, email: key))
            if out.count == limit { break }
        }
        return out
    }

    /// People myOS knows whose name or address contains every word typed, the closest first.
    static func fromPeople(query: String, url: URL = PeopleDatabase.defaultURL, limit: Int = 12) -> [CalendarGuest] {
        let words = self.words(query)
        guard !words.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        let match = words.map { _ in "(lower(p.display_name) LIKE ? OR i.value_norm LIKE ?)" }.joined(separator: " AND ")
        let sql = """
        SELECT p.display_name, i.value_norm FROM identity i
        JOIN person p ON p.id = i.person_id AND p.merged_into IS NULL
        LEFT JOIN person_score s ON s.person_id = p.id
        WHERE i.kind = 'email' AND \(match)
        ORDER BY COALESCE(s.strength, 0) DESC, p.display_name LIMIT \(limit)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, word) in words.enumerated() {
            sqlite3_bind_text(statement, Int32(2 * i + 1), "%\(word)%", -1, transient)
            sqlite3_bind_text(statement, Int32(2 * i + 2), "%\(word)%", -1, transient)
        }
        var out: [CalendarGuest] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0), let email = sqlite3_column_text(statement, 1) else { continue }
            out.append(CalendarGuest(name: String(cString: name), email: String(cString: email)))
        }
        return out
    }

    /// Contacts whose name matches the first word typed (the rest of the words narrow the result), with each of their addresses.
    static func fromContacts(query: String, limit: Int = 12) -> [CalendarGuest] {
        let words = self.words(query)
        guard let first = words.first, !first.contains("@"), CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        guard let found = try? CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: first), keysToFetch: keys) else { return [] }
        var out: [CalendarGuest] = []
        for contact in found {
            let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            guard words.dropFirst().allSatisfy({ name.lowercased().contains($0) }) else { continue }
            for address in contact.emailAddresses { out.append(CalendarGuest(name: name, email: String(address.value))) }
            if out.count >= limit { break }
        }
        return out
    }

    /// Who to offer for what has been typed: matches from people and contacts, then the typed address itself if it is a whole address that
    /// was not found. Blocking (a database and Contacts), so call it off the main thread.
    static func suggestions(for query: String, excluding: Set<String>, limit: Int = 4) -> [CalendarGuest] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        var lists = [self.fromPeople(query: typed), self.fromContacts(query: typed)]
        if self.looksLikeEmail(typed) { lists.append([CalendarGuest(name: "", email: typed)]) }
        return self.merge(lists, excluding: excluding, limit: limit)
    }
}

/// Why guests could not be added, in words.
nonisolated struct CalendarInviteFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { self.message }
}

/// Adding guests to an event that was just saved. EventKit cannot add attendees to an event, so the Calendar app does it (through
/// AppleScript); the calendar's own account then sends the invitations when the event syncs.
nonisolated enum CalendarInvites {
    /// `text` as an AppleScript string literal.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\""
    }

    /// The script: finds the event just saved (by calendar, title and start time) and adds each guest. The start time is built from numbers,
    /// so it does not depend on the language or date format of the Mac.
    static func script(calendarIdentifier: String, title: String, start: Date, guests: [CalendarGuest], calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        var lines = [
            "set theStart to current date",
            "set day of theStart to 1",
            "set year of theStart to \(c.year ?? 2026)",
            "set month of theStart to \(c.month ?? 1)",
            "set day of theStart to \(c.day ?? 1)",
            "set hours of theStart to \(c.hour ?? 0)",
            "set minutes of theStart to \(c.minute ?? 0)",
            "set seconds of theStart to 0",
            "tell application \"Calendar\"",
            "set theCalendar to first calendar whose calendarIdentifier is \(self.literal(calendarIdentifier))",
            "set found to (every event of theCalendar whose summary is \(self.literal(title)) and start date is theStart)",
            "if (count of found) is 0 then error \"The new event was not found in Calendar.\"",
            "set theEvent to item -1 of found",
            "tell theEvent",
        ]
        for guest in guests {
            lines.append("make new attendee at end of attendees with properties {email:\(self.literal(guest.email))}")
        }
        lines += ["end tell", "end tell"]
        return lines.joined(separator: "\n")
    }

    /// A failure of osascript in words: the permission case says where to allow it, anything else is Calendar's own message.
    static func failure(fromStandardError text: String) -> CalendarInviteFailure {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-1743") {
            return CalendarInviteFailure(message: "myOS Engine is not allowed to control Calendar. Allow it in System Settings, Privacy & Security, Automation.")
        }
        return CalendarInviteFailure(message: trimmed.isEmpty ? "Calendar did not accept the guests." : trimmed)
    }

    /// Runs `script` with osascript off the main thread (the first call may wait while Calendar opens and while macOS asks for permission).
    static func run(_ script: String, timeout: TimeInterval = 60) async -> Result<Void, CalendarInviteFailure> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<Void, CalendarInviteFailure>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
                let input = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do { try process.run() } catch {
                    continuation.resume(returning: .failure(CalendarInviteFailure(message: "Could not start osascript: \(error.localizedDescription)")))
                    return
                }
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    continuation.resume(returning: .failure(CalendarInviteFailure(message: "Calendar took too long to answer.")))
                    return
                }
                let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: process.terminationStatus == 0 ? .success(()) : .failure(Self.failure(fromStandardError: text)))
            }
        }
    }

    /// Adds `guests` to the event that was just saved.
    static func addGuests(_ guests: [CalendarGuest], calendarIdentifier: String, title: String, start: Date) async -> Result<Void, CalendarInviteFailure> {
        guard !guests.isEmpty else { return .success(()) }
        return await self.run(self.script(calendarIdentifier: calendarIdentifier, title: title, start: start, guests: guests))
    }
}
