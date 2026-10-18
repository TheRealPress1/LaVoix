import CryptoKit
import Foundation

/// Relationship signals from Messages, for myOS: how much, how recently, who writes first, how fast replies come. Built
/// only from who sent a message and when; message text is never read, so none of it can leak into the export.
nonisolated enum MessageActivity {
    struct Row: Equatable {
        let chat: String
        let handle: String
        let fromMe: Bool
        let date: Date
    }

    struct Day: Codable, Equatable {
        var day: String
        var sent: Int
        var received: Int
    }

    struct Conversation: Codable, Equatable {
        var external_id: String
        var hint_kind: String
        var hint_value: String
        /// Enough real history to make a person worth tracking: >= 25 messages, >= 5 from you, spread over >= 7 days.
        var qualifies: Bool
        var first_at: String
        var last_at: String
        var last_from_me_at: String?
        var last_from_them_at: String?
        var total: Int
        var from_me: Int
        var active_days: Int
        var median_reply_seconds: Int?
        /// Per-day counts for days that have ended (today is still changing and is left out).
        var days: [Day]
    }

    static let minTotal = 25
    static let minFromMe = 5
    static let minSpanDays = 7
    static let maxReplySeconds: TimeInterval = 7 * 24 * 3600

    /// A handle is a usable identity only if it is an email or has at least 7 digits.
    static func hintKind(for handle: String) -> String? {
        if handle.contains("@") { return "email" }
        return handle.filter(\.isNumber).count >= 7 ? "phone" : nil
    }

    static func normalizedForExclusion(_ handle: String) -> String {
        let lowered = handle.lowercased().filter { !$0.isWhitespace && !"()-.".contains($0) }
        return lowered
    }

    /// `rows` must be ordered by chat, then date.
    static func aggregate(
        rows: [Row], excluded: Set<String> = [], now: Date, calendar: Calendar, maxDays: Int = 7300
    ) -> [Conversation] {
        let iso = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: now)
        let oldest = calendar.date(byAdding: .day, value: -maxDays, to: now) ?? .distantPast

        var result: [Conversation] = []
        var index = 0
        while index < rows.count {
            let chat = rows[index].chat
            var end = index
            while end < rows.count, rows[end].chat == chat { end += 1 }
            defer { index = end }
            let group = rows[index..<end]
            guard let handle = group.first?.handle, let kind = hintKind(for: handle) else { continue }
            if excluded.contains(normalizedForExclusion(handle)) { continue }

            var fromMe = 0
            var lastMe: Date?, lastThem: Date?
            var activeDays = Set<String>()
            var perDay: [String: (sent: Int, received: Int)] = [:]
            var latencies: [TimeInterval] = []
            var pendingTheirs: Date?
            for row in group {
                let day = dayFormatter.string(from: row.date)
                activeDays.insert(day)
                if row.fromMe {
                    fromMe += 1
                    lastMe = row.date
                    if let pending = pendingTheirs {
                        let latency = row.date.timeIntervalSince(pending)
                        if latency >= 0, latency <= maxReplySeconds { latencies.append(latency) }
                        pendingTheirs = nil
                    }
                } else {
                    lastThem = row.date
                    if pendingTheirs == nil { pendingTheirs = row.date }
                }
                if row.date >= oldest, day != today {
                    var entry = perDay[day] ?? (0, 0)
                    if row.fromMe { entry.sent += 1 } else { entry.received += 1 }
                    perDay[day] = entry
                }
            }
            let first = group.first!.date, last = group.last!.date
            let spanDays = last.timeIntervalSince(first) / 86400
            let median: Int? = latencies.isEmpty ? nil : {
                let sorted = latencies.sorted()
                let mid = sorted.count / 2
                let value = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                return Int(value.rounded())
            }()
            result.append(Conversation(
                external_id: "imessage:\(chat)",
                hint_kind: kind,
                hint_value: handle,
                qualifies: group.count >= minTotal && fromMe >= minFromMe && spanDays >= Double(minSpanDays),
                first_at: iso.string(from: first),
                last_at: iso.string(from: last),
                last_from_me_at: lastMe.map(iso.string(from:)),
                last_from_them_at: lastThem.map(iso.string(from:)),
                total: group.count,
                from_me: fromMe,
                active_days: activeDays.count,
                median_reply_seconds: median,
                days: perDay.keys.sorted().map { Day(day: $0, sent: perDay[$0]!.sent, received: perDay[$0]!.received) }
            ))
        }
        return result.sorted { $0.external_id < $1.external_id }
    }

    // MARK: - Snapshot file

    private struct Snapshot: Codable {
        var schema = 1
        var source = "imessage"
        var generated_at: String
        var conversations: [Conversation]
    }

    static let lastHashKey = "MessagesInboxLastHash"
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
        return "messages-\(formatter.string(from: date)).json"
    }

    /// Writes `<data>/inbox/messages/messages-<UTC>.json` unless nothing changed since the last snapshot.
    @discardableResult
    static func write(
        conversations: [Conversation], dataDirectory: URL, defaults: UserDefaults = .standard, now: Date = Date()
    ) throws -> URL? {
        let hash = contentHash(conversations)
        if defaults.string(forKey: lastHashKey) == hash { return nil }
        let directory = dataDirectory.appendingPathComponent("inbox/messages", isDirectory: true)
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
            .filter { $0.hasPrefix("messages-") && $0.hasSuffix(".json") }.sorted()
        for old in files.dropLast(keptSnapshots) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        return target
    }
}

/// Keeps the Messages snapshot current while sharing is on: shortly after launch, then every ten minutes.
@MainActor
final class MessagesInboxScheduler {
    static let shared = MessagesInboxScheduler()

    private var loop: Task<Void, Never>?

    func start() {
        guard self.loop == nil else { return }
        DebugLogger.shared.info("Messages sharing scheduler started", source: "MessagesInbox")
        self.loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
            while !Task.isCancelled {
                self?.exportNow()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    func exportNow() {
        let settings = SettingsStore.shared
        guard settings.shareMessagesWithMyOSEnabled else { return }
        guard let data = ContactsInboxExporter.dataDirectory(brainOverride: settings.meetingBrainFolderOverride) else {
            DebugLogger.shared.warning("Messages export skipped: myOS data folder not found", source: "MessagesInbox")
            return
        }
        let excluded = Set(settings.messagesExcludedHandles
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { MessageActivity.normalizedForExclusion(String($0)) }
            .filter { !$0.isEmpty })
        let keepText = settings.keepMessageTextForMyOSEnabled
        Task.detached(priority: .utility) {
            let database = MessagesDatabase()
            let access = database.checkAccess()
            guard access == .granted else {
                DebugLogger.shared.warning("Messages export skipped: no access to the Messages database (\(access))", source: "MessagesInbox")
                return
            }
            let started = Date()
            guard let rows = database.activityRows() else {
                DebugLogger.shared.warning("Messages export skipped: the Messages database could not be read right now", source: "MessagesInbox")
                return
            }
            let conversations = MessageActivity.aggregate(rows: rows, excluded: excluded, now: Date(), calendar: .current)
            DebugLogger.shared.info("Read \(rows.count) message records into \(conversations.count) conversations in \(Int(Date().timeIntervalSince(started) * 1000)) ms", source: "MessagesInbox")
            // Message text stays on this Mac, in a private database outside the synced myOS folder.
            if keepText {
                let qualified = Set(conversations.filter(\.qualifies).map { String($0.external_id.dropFirst("imessage:".count)) })
                let t0 = Date()
                if let r = PrivateMessageStore.sync(reader: database, qualified: qualified, excluded: excluded) {
                    DebugLogger.shared.info("Private message store: +\(r.added) messages, \(r.total) kept (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)", source: "MessagesInbox")
                } else {
                    DebugLogger.shared.warning("Private message store could not be updated", source: "MessagesInbox")
                }
            } else {
                PrivateMessageStore.purge()
            }
            // Who is in which group chat (names and members, never text), for the people map.
            if let groups = database.groupChats() {
                let shared = GroupChatsExport.prepare(groups, excluded: excluded)
                do { try GroupChatsExport.write(shared) } catch { DebugLogger.shared.warning("Group chats export failed: \(error.localizedDescription)", source: "MessagesInbox") }
            }
            do {
                if let file = try MessageActivity.write(conversations: conversations, dataDirectory: data) {
                    DebugLogger.shared.info("Shared \(conversations.count) conversations' activity with myOS (\(file.lastPathComponent))", source: "MessagesInbox")
                } else {
                    DebugLogger.shared.info("Messages activity unchanged since the last snapshot", source: "MessagesInbox")
                }
            } catch {
                DebugLogger.shared.warning("Messages export failed: \(error.localizedDescription)", source: "MessagesInbox")
            }
        }
    }
}
