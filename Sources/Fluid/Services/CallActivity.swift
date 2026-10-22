import CryptoKit
import Foundation
import SQLite3

/// Relationship signals from phone and FaceTime calls, for myOS: how many, how long, who calls whom, how many were missed. Built from the
/// call history database macOS keeps (`~/Library/Application Support/CallHistoryDB/CallHistory.storedata`), read-only. Only the other
/// party's number or address, the time, the length and the direction are read; names and anything said on a call are never involved.
nonisolated enum CallActivity {
    enum Kind: String, Codable { case phone, facetimeVideo = "facetime_video", facetimeAudio = "facetime_audio" }

    struct Row: Equatable {
        let handle: String
        let date: Date
        let seconds: Double
        let fromMe: Bool
        let answered: Bool
        let kind: Kind
    }

    struct Day: Codable, Equatable {
        var day: String
        var calls: Int
        var answered: Int
        var minutes: Int
    }

    struct Conversation: Codable, Equatable {
        var external_id: String
        var hint_kind: String
        var hint_value: String
        /// Enough real calls to make a person worth tracking: >= 3 answered calls and >= 10 minutes talked, if they are not in your contacts.
        var qualifies: Bool
        var first_at: String
        var last_at: String
        var last_from_me_at: String?
        var last_from_them_at: String?
        var total: Int
        var from_me: Int
        var answered: Int
        /// Incoming calls nobody picked up.
        var missed: Int
        var facetime: Int
        var video: Int
        var talk_minutes: Int
        var active_days: Int
        /// Per-day counts for days that have ended (today is still changing and is left out).
        var days: [Day]
    }

    static let minAnswered = 3
    static let minTalkSeconds: Double = 600

    /// `rows` can come in any order.
    static func aggregate(rows: [Row], excluded: Set<String> = [], now: Date, calendar: Calendar, maxDays: Int = 7300) -> [Conversation] {
        let iso = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: now)
        let oldest = calendar.date(byAdding: .day, value: -maxDays, to: now) ?? .distantPast

        var byHandle: [String: [Row]] = [:]
        for row in rows {
            guard MessageActivity.hintKind(for: row.handle) != nil, !excluded.contains(MessageActivity.normalizedForExclusion(row.handle)) else { continue }
            byHandle[Self.key(for: row.handle), default: []].append(row)
        }
        var result: [Conversation] = []
        for (_, group) in byHandle {
            let sorted = group.sorted { $0.date < $1.date }
            guard let handle = sorted.first?.handle, let kind = MessageActivity.hintKind(for: handle) else { continue }
            var activeDays = Set<String>()
            var perDay: [String: (calls: Int, answered: Int, seconds: Double)] = [:]
            var lastMe: Date?, lastThem: Date?
            var fromMe = 0, answered = 0, missed = 0, facetime = 0, video = 0
            var talk: Double = 0
            for row in sorted {
                let day = dayFormatter.string(from: row.date)
                activeDays.insert(day)
                if row.fromMe { fromMe += 1; lastMe = row.date } else { lastThem = row.date }
                if row.answered { answered += 1; talk += max(row.seconds, 0) } else if !row.fromMe { missed += 1 }
                if row.kind != .phone { facetime += 1 }
                if row.kind == .facetimeVideo { video += 1 }
                if row.date >= oldest, day != today {
                    var entry = perDay[day] ?? (0, 0, 0)
                    entry.calls += 1
                    if row.answered { entry.answered += 1; entry.seconds += max(row.seconds, 0) }
                    perDay[day] = entry
                }
            }
            let first = sorted.first!.date, last = sorted.last!.date
            result.append(Conversation(
                external_id: "calls:\(Self.key(for: handle))",
                hint_kind: kind,
                hint_value: handle,
                qualifies: answered >= minAnswered && talk >= minTalkSeconds,
                first_at: iso.string(from: first),
                last_at: iso.string(from: last),
                last_from_me_at: lastMe.map(iso.string(from:)),
                last_from_them_at: lastThem.map(iso.string(from:)),
                total: sorted.count,
                from_me: fromMe,
                answered: answered,
                missed: missed,
                facetime: facetime,
                video: video,
                talk_minutes: Int((talk / 60).rounded()),
                active_days: activeDays.count,
                days: perDay.keys.sorted().map { Day(day: $0, calls: perDay[$0]!.calls, answered: perDay[$0]!.answered, minutes: Int((perDay[$0]!.seconds / 60).rounded())) }
            ))
        }
        return result.sorted { $0.external_id < $1.external_id }
    }

    /// One key per person-handle: digits only for a number (so "+1 (415) 555-1234" and "+14155551234" are one), lower case for an address.
    static func key(for handle: String) -> String {
        handle.contains("@") ? handle.lowercased() : handle.filter(\.isNumber).suffix(10).description
    }

    // MARK: - Reading the call history

    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CallHistoryDB/CallHistory.storedata")

    enum ReadResult: Equatable {
        case rows([Row])
        /// macOS is blocking the file: Full Disk Access is needed.
        case denied
        case missing
        /// Opened, but the tables did not look like call history. The names of the columns found are in the log, nothing else.
        case unrecognised
        case busy
    }

    /// Read-only. Message and call text never exists here; only the columns below are read, found by name so a different macOS layout is
    /// noticed instead of read wrongly.
    static func read(url: URL = defaultURL) -> ReadResult {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor < 0 { return errno == ENOENT ? .missing : .denied }
        close(descriptor)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { sqlite3_close(db); return .busy }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)

        var columns = Set<String>()
        var info: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(ZCALLRECORD)", -1, &info, nil) == SQLITE_OK {
            while sqlite3_step(info) == SQLITE_ROW, let c = sqlite3_column_text(info, 1) { columns.insert(String(cString: c)) }
        }
        sqlite3_finalize(info)
        guard columns.contains("ZDATE"), columns.contains("ZADDRESS") else {
            DebugLogger.shared.warning("Call history layout not recognised; columns: \(columns.sorted().joined(separator: ", "))", source: "CallsInbox")
            return .unrecognised
        }
        func col(_ name: String, or fallback: String) -> String { columns.contains(name) ? name : fallback }
        let sql = """
        SELECT CAST(ZADDRESS AS TEXT), ZDATE, \(col("ZDURATION", or: "0")), \(col("ZORIGINATED", or: "0")), \(col("ZANSWERED", or: "0")),
               \(col("ZCALLTYPE", or: "1")), \(col("ZSERVICE_PROVIDER", or: "''"))
        FROM ZCALLRECORD WHERE ZADDRESS IS NOT NULL ORDER BY ZDATE
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { sqlite3_finalize(statement); return .busy }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let handle = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let provider = sqlite3_column_text(statement, 6).map { String(cString: $0) } ?? ""
            rows.append(Row(
                handle: handle,
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1)),
                seconds: sqlite3_column_double(statement, 2),
                fromMe: sqlite3_column_int(statement, 3) != 0,
                answered: sqlite3_column_int(statement, 4) != 0,
                kind: Self.kind(callType: Int(sqlite3_column_int(statement, 5)), provider: provider)
            ))
            code = sqlite3_step(statement)
        }
        return code == SQLITE_DONE ? .rows(rows) : .busy
    }

    /// 8 is a FaceTime video call, 16 a FaceTime audio call, anything else on the FaceTime service is audio, the rest is a phone call.
    static func kind(callType: Int, provider: String) -> Kind {
        switch callType {
        case 8: return .facetimeVideo
        case 16: return .facetimeAudio
        default: return provider.lowercased().contains("facetime") ? .facetimeAudio : .phone
        }
    }

    // MARK: - Snapshot file

    private struct Snapshot: Codable {
        var schema = 1
        var source = "calls"
        var generated_at: String
        var conversations: [Conversation]
    }

    static let lastHashKey = "CallsInboxLastHash"
    static let keptSnapshots = 3

    static func contentHash(_ conversations: [Conversation]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(conversations)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "calls-\(formatter.string(from: date)).json"
    }

    /// Writes `<data>/inbox/calls/calls-<UTC>.json` unless nothing changed since the last snapshot.
    @discardableResult
    static func write(conversations: [Conversation], dataDirectory: URL, defaults: UserDefaults = .standard, now: Date = Date()) throws -> URL? {
        let hash = contentHash(conversations)
        if defaults.string(forKey: lastHashKey) == hash { return nil }
        let directory = dataDirectory.appendingPathComponent("inbox/calls", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Snapshot(generated_at: ISO8601DateFormatter().string(from: now), conversations: conversations))
        let name = fileName(for: now)
        let target = directory.appendingPathComponent(name)
        let temp = directory.appendingPathComponent(".\(name).tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        defaults.set(hash, forKey: lastHashKey)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("calls-") && $0.hasSuffix(".json") }.sorted()
        for old in files.dropLast(keptSnapshots) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        return target
    }

    /// Reads the call history and writes the snapshot, logging only counts. Safe to call from a background task.
    static func exportNow(dataDirectory: URL, excluded: Set<String>) {
        switch read() {
        case .rows(let rows):
            let conversations = aggregate(rows: rows, excluded: excluded, now: Date(), calendar: .current)
            DebugLogger.shared.info("Read \(rows.count) call records into \(conversations.count) people", source: "CallsInbox")
            do {
                if let file = try write(conversations: conversations, dataDirectory: dataDirectory) {
                    DebugLogger.shared.info("Shared call activity with myOS (\(file.lastPathComponent))", source: "CallsInbox")
                } else {
                    DebugLogger.shared.info("Call activity unchanged since the last snapshot", source: "CallsInbox")
                }
            } catch {
                DebugLogger.shared.warning("Calls export failed: \(error.localizedDescription)", source: "CallsInbox")
            }
        case .denied: DebugLogger.shared.warning("Calls export skipped: no access to the call history (needs Full Disk Access)", source: "CallsInbox")
        case .missing: DebugLogger.shared.info("Calls export skipped: this Mac has no call history file", source: "CallsInbox")
        case .unrecognised: DebugLogger.shared.warning("Calls export skipped: call history layout not recognised", source: "CallsInbox")
        case .busy: DebugLogger.shared.warning("Calls export skipped: the call history could not be read right now", source: "CallsInbox")
        }
    }
}
