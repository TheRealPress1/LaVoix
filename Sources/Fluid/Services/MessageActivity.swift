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

    /// Counts one chat at a time as the rows arrive, so only the chat being read is held in memory (not every message on the Mac).
    /// `rows` must arrive ordered by chat, then date.
    struct Aggregator {
        private let excluded: Set<String>
        private let now: Date
        private let calendar: Calendar
        private let iso = ISO8601DateFormatter()
        private let dayFormatter: DateFormatter
        private let today: String
        private let oldest: Date

        private var result: [Conversation] = []
        private var chat: String?
        private var skipping = false
        private var handle = ""
        private var kind = ""
        private var count = 0, fromMe = 0
        private var lastMe: Date?, lastThem: Date?
        private var first: Date?, last: Date?
        private var activeDays = Set<String>()
        private var perDay: [String: (sent: Int, received: Int)] = [:]
        private var latencies: [TimeInterval] = []
        private var pendingTheirs: Date?

        init(excluded: Set<String> = [], now: Date, calendar: Calendar, maxDays: Int = 7300) {
            self.excluded = excluded
            self.now = now
            self.calendar = calendar
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            self.dayFormatter = f
            self.today = f.string(from: now)
            self.oldest = calendar.date(byAdding: .day, value: -maxDays, to: now) ?? .distantPast
        }

        mutating func feed(_ row: Row) {
            if row.chat != self.chat {
                self.finishChat()
                self.chat = row.chat
                self.handle = row.handle
                if let k = MessageActivity.hintKind(for: row.handle), !self.excluded.contains(MessageActivity.normalizedForExclusion(row.handle)) {
                    self.kind = k
                    self.skipping = false
                } else {
                    self.skipping = true
                }
            }
            if self.skipping { return }
            let day = self.dayFormatter.string(from: row.date)
            self.count += 1
            self.activeDays.insert(day)
            if self.first == nil { self.first = row.date }
            self.last = row.date
            if row.fromMe {
                self.fromMe += 1
                self.lastMe = row.date
                if let pending = self.pendingTheirs {
                    let latency = row.date.timeIntervalSince(pending)
                    if latency >= 0, latency <= MessageActivity.maxReplySeconds { self.latencies.append(latency) }
                    self.pendingTheirs = nil
                }
            } else {
                self.lastThem = row.date
                if self.pendingTheirs == nil { self.pendingTheirs = row.date }
            }
            if row.date >= self.oldest, day != self.today {
                var entry = self.perDay[day] ?? (0, 0)
                if row.fromMe { entry.sent += 1 } else { entry.received += 1 }
                self.perDay[day] = entry
            }
        }

        private mutating func finishChat() {
            defer {
                self.chat = nil
                self.count = 0
                self.fromMe = 0
                self.lastMe = nil
                self.lastThem = nil
                self.first = nil
                self.last = nil
                self.activeDays.removeAll(keepingCapacity: true)
                self.perDay.removeAll(keepingCapacity: true)
                self.latencies.removeAll(keepingCapacity: true)
                self.pendingTheirs = nil
            }
            guard let chat = self.chat, !self.skipping, self.count > 0, let first = self.first, let last = self.last else { return }
            let spanDays = last.timeIntervalSince(first) / 86400
            let median: Int? = self.latencies.isEmpty ? nil : {
                let sorted = self.latencies.sorted()
                let mid = sorted.count / 2
                let value = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                return Int(value.rounded())
            }()
            self.result.append(Conversation(
                external_id: "imessage:\(chat)",
                hint_kind: self.kind,
                hint_value: self.handle,
                qualifies: self.count >= MessageActivity.minTotal && self.fromMe >= MessageActivity.minFromMe && spanDays >= Double(MessageActivity.minSpanDays),
                first_at: self.iso.string(from: first),
                last_at: self.iso.string(from: last),
                last_from_me_at: self.lastMe.map(self.iso.string(from:)),
                last_from_them_at: self.lastThem.map(self.iso.string(from:)),
                total: self.count,
                from_me: self.fromMe,
                active_days: self.activeDays.count,
                median_reply_seconds: median,
                days: self.perDay.keys.sorted().map { Day(day: $0, sent: self.perDay[$0]!.sent, received: self.perDay[$0]!.received) }
            ))
        }

        mutating func finish() -> [Conversation] {
            self.finishChat()
            return self.result.sorted { $0.external_id < $1.external_id }
        }
    }

    /// `rows` must be ordered by chat, then date. (The same counting as `Aggregator`, for a list that is already in memory.)
    static func aggregate(
        rows: [Row], excluded: Set<String> = [], now: Date, calendar: Calendar, maxDays: Int = 7300
    ) -> [Conversation] {
        var aggregator = Aggregator(excluded: excluded, now: now, calendar: calendar, maxDays: maxDays)
        for row in rows { aggregator.feed(row) }
        return aggregator.finish()
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

/// How much memory this process holds, in megabytes (what Activity Monitor calls Memory), for the log.
nonisolated enum MemoryProbe {
    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    static func footprintMB() -> Int { Int((info()?.phys_footprint ?? 0) / 1_048_576) }
    static func peakMB() -> Int { Int((info()?.ledger_phys_footprint_peak ?? 0) / 1_048_576) }
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
            // Calls and FaceTime come from their own database, so they do not wait on Messages being readable. Its own switch
            // (`defaults write com.myos.engine ShareCallsWithMyOSEnabled -bool false`) so it can be turned off without Messages.
            if UserDefaults.standard.object(forKey: "ShareCallsWithMyOSEnabled") as? Bool ?? true {
                CallActivity.exportNow(dataDirectory: data, excluded: excluded)
            }
            let database = MessagesDatabase()
            let access = database.checkAccess()
            guard access == .granted else {
                DebugLogger.shared.warning("Messages export skipped: no access to the Messages database (\(access))", source: "MessagesInbox")
                return
            }
            let started = Date()
            let before = MemoryProbe.footprintMB()
            // Counted as the rows arrive. (`defaults write com.myos.engine MessagesActivityLegacyRead -bool true` reads them all into a list
            // first, the old way, to compare the memory.)
            var rowCount = 0
            let conversations: [MessageActivity.Conversation]
            if UserDefaults.standard.bool(forKey: "MessagesActivityLegacyRead") {
                guard let rows = database.activityRows() else {
                    DebugLogger.shared.warning("Messages export skipped: the Messages database could not be read right now", source: "MessagesInbox")
                    return
                }
                rowCount = rows.count
                conversations = MessageActivity.aggregate(rows: rows, excluded: excluded, now: Date(), calendar: .current)
            } else {
                var aggregator = MessageActivity.Aggregator(excluded: excluded, now: Date(), calendar: .current)
                guard database.streamActivityRows({ rowCount += 1; aggregator.feed($0) }) else {
                    DebugLogger.shared.warning("Messages export skipped: the Messages database could not be read right now", source: "MessagesInbox")
                    return
                }
                conversations = aggregator.finish()
            }
            let after = MemoryProbe.footprintMB()
            DebugLogger.shared.info("Read \(rowCount) message records into \(conversations.count) conversations in \(Int(Date().timeIntervalSince(started) * 1000)) ms (memory \(before) -> \(after) MB, peak \(MemoryProbe.peakMB()) MB)", source: "MessagesInbox")
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
                do {
                    try GroupChatsExport.write(shared)
                    DebugLogger.shared.info("Shared \(shared.count) of \(groups.count) group chats with myOS (members and counts only)", source: "MessagesInbox")
                } catch { DebugLogger.shared.warning("Group chats export failed: \(error.localizedDescription)", source: "MessagesInbox") }
            } else {
                DebugLogger.shared.warning("Group chats could not be read from the Messages database", source: "MessagesInbox")
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
