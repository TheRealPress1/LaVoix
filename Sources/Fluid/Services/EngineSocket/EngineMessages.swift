import Foundation

/// A one-to-one text conversation for myOS's People page: its latest messages, and a reply you typed there. It only ever opens a chat that
/// already exists in Messages with exactly that one person (never a group), and it sends only when asked to with `confirm: true`, which the
/// People page sets only when you press Send. Nothing here is logged. macOS must allow the engine to read Messages (Full Disk Access, as the
/// notch's Messages tab already needs) and to control Messages (asked once, on the first send).
nonisolated protocol EngineMessagesProviding: Sendable {
    /// {chat_guid, items: [{id, text, at (ISO-8601), from_me}]}, oldest first.
    func thread(handles: [String], limit: Int) async throws -> [String: Any]
    func send(handles: [String], text: String) async throws
}

nonisolated enum EngineMessagesError: LocalizedError, Equatable {
    case noAccess, noChat, badText
    var errorDescription: String? {
        switch self {
        case .noAccess: "The myOS engine can't read Messages. Give it Full Disk Access in System Settings > Privacy & Security."
        case .noChat: "There is no one-to-one conversation with this person in Messages yet. Start it in Messages first."
        case .badText: "Write something first (up to 4,000 characters)."
        }
    }
}

nonisolated enum MessagesRules {
    static let maxLength = 4000

    /// The handles to look for: trimmed, without blanks or duplicates, at most a dozen.
    static func handles(_ raw: Any?) -> [String] {
        var seen = Set<String>()
        return ((raw as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    /// The text to send, or nil when there is none or it is too long.
    static func text(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.count > maxLength ? nil : t
    }
}

nonisolated struct LiveEngineMessages: EngineMessagesProviding {
    private let database = MessagesDatabase()

    private func chat(_ handles: [String]) throws -> (id: Int64, guid: String) {
        guard self.database.checkAccess() == .granted else { throw EngineMessagesError.noAccess }
        guard let chats = self.database.oneToOneChat(handles: handles) else { throw EngineMessagesError.noAccess }
        guard let first = chats.first else { throw EngineMessagesError.noChat }
        return first
    }

    func thread(handles: [String], limit: Int) async throws -> [String: Any] {
        let chat = try self.chat(handles)
        guard let messages = self.database.messages(chatID: chat.id, limit: min(max(limit, 1), 200)) else { throw EngineMessagesError.noAccess }
        let iso = ISO8601DateFormatter()
        return [
            "chat_guid": chat.guid,
            "items": messages.map { ["id": $0.id, "text": $0.text, "at": iso.string(from: $0.date), "from_me": $0.isFromMe] as [String: Any] },
        ]
    }

    func send(handles: [String], text: String) async throws {
        guard let body = MessagesRules.text(text) else { throw EngineMessagesError.badText }
        let chat = try self.chat(handles)
        try await MessagesSender.send(body, toChat: chat.guid)
    }
}
