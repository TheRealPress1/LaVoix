import Foundation
import UniformTypeIdentifiers

struct MessageConversation: Identifiable, Equatable {
    let id: Int64
    let guid: String
    /// The group's name, or the other person's phone number / email until Contacts resolves a name.
    var title: String
    let handles: [String]
    let isGroup: Bool
    var lastText: String
    let lastDate: Date
    let lastIsFromMe: Bool
    var unreadCount: Int
    /// True when the group has been given a name; unnamed groups are shown by who is in them.
    var hasGroupName = false
    /// When the newest message is only a file: that file, so the list can show a tiny picture of it beside "Photo".
    var lastFile: MessageAttachment? = nil

    /// The same conversation with a different preview line (a message that is only a file reads "Photo", not "Attachment").
    func withLastText(_ text: String, file: MessageAttachment? = nil) -> MessageConversation {
        var copy = self
        copy.lastText = text
        copy.lastFile = file
        return copy
    }

    /// The same conversation with a different unread count (the notch clears its own unread dot once you have looked at a chat).
    func withUnread(_ count: Int) -> MessageConversation {
        var copy = self
        copy.unreadCount = count
        return copy
    }
}

struct ThreadMessage: Identifiable, Equatable {
    let id: Int64
    let text: String
    let date: Date
    let isFromMe: Bool
    let senderHandle: String
    /// A message of yours that Messages could not deliver (it shows as "Not Delivered" there).
    var failed = false
    /// The files that came with the message, as Messages lists them (a photo, a video, a PDF...).
    var attachments: [MessageAttachment] = []
    /// `text` is only the stand-in "Attachment" (the message had no words of its own), so the files are shown instead of it.
    var textIsPlaceholder = false
}

/// Whether a file you sent has turned up in the thread as a real message of yours. A message only shown as pending (it has no real id yet) does not count.
nonisolated enum SendConfirmation {
    /// A real message from you with a file, sent at or after `since` (ten seconds of slack for the clocks of Messages and this Mac).
    static func fileAppeared(in thread: [ThreadMessage], since: Date) -> Bool {
        thread.contains { $0.id > 0 && $0.isFromMe && !$0.attachments.isEmpty && $0.date >= since.addingTimeInterval(-10) }
    }
}

/// The emojis the reply box offers, and how the ones used last are kept. Common ones, in the order people reach for them; each is one character on screen.
nonisolated enum EmojiPalette {
    static let all: [String] = [
        "😀", "😂", "🤣", "😊", "😍", "🥰", "😘", "😎", "🤔", "😭", "😅", "😉", "🙂", "🙃", "😴", "🥺",
        "😢", "😡", "🤯", "🥳", "🙏", "👍", "👎", "👏", "🙌", "💪", "🤝", "👀", "🔥", "✨", "💯", "❤️",
        "😬", "😮", "😤", "🤦", "🎉", "✅", "💀", "😈",
    ]

    /// How many recently used emojis are kept.
    static let recentLimit = 8

    /// `emoji` put first among the recents, once, and the list cut to `recentLimit`.
    static func recording(_ emoji: String, in recents: [String]) -> [String] {
        Array(([emoji] + recents.filter { $0 != emoji }).prefix(self.recentLimit))
    }

    /// What the strip shows: the recents first, then everything else once.
    static func strip(recents: [String]) -> [String] {
        recents + self.all.filter { !recents.contains($0) }
    }
}

enum NotchEmojiSettings {
    private static let key = "LaVoixNotchEmojiRecents"

    static var recents: [String] {
        get { UserDefaults.standard.stringArray(forKey: self.key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: self.key) }
    }
}

/// The centred time above messages in a conversation, as iMessage shows it: above the first message shown and above any message that comes after a pause
/// of an hour or more, so messages sent at different times can be told apart without a time on every bubble.
nonisolated enum ThreadTimestamp {
    /// How long a pause has to be before the next message gets a time above it.
    static let pause: TimeInterval = 3600

    /// Does the message at `index` get a time above it?
    static func isShown(at index: Int, in thread: [ThreadMessage]) -> Bool {
        guard thread.indices.contains(index) else { return false }
        return index == 0 || thread[index].date.timeIntervalSince(thread[index - 1].date) >= self.pause
    }

    /// "Today 7:09 PM", "Yesterday 7:09 PM", "Monday 3:14 PM" (the past week), "Mon, Aug 24 at 3:14 PM" (earlier this year), "Aug 24, 2025 at 3:14 PM".
    static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        func formatter() -> DateFormatter {
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            return f
        }
        func format(_ template: String) -> String {
            let f = formatter()
            f.setLocalizedDateFormatFromTemplate(template)
            return f.string(from: date)
        }
        let time: String = {
            let f = formatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f.string(from: date)
        }()
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days > 0, days < 7 { return "\(format("EEEE")) \(time)" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return "\(format("EEEMMMd")) at \(time)" }
        return "\(format("yMMMd")) at \(time)"
    }
}

/// A file attached to a message. Its bytes stay where Messages keeps them; only the path is held here.
nonisolated struct MessageAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image, video, audio, pdf, file
    }

    /// The row in Messages' attachment table (negative for a file that was just sent from the notch).
    let id: Int64
    let path: String
    let name: String
    let kind: Kind
    var isSticker = false

    var url: URL { URL(fileURLWithPath: self.path) }

    /// Whether the file is on this Mac (Messages can keep old attachments in iCloud only).
    var exists: Bool { FileManager.default.fileExists(atPath: self.path) }

    /// What the file is, from the mime type Messages recorded, else its type identifier, else the file name's extension.
    static func kind(mime: String?, uti: String?, name: String) -> Kind {
        // The mime type's family is usually enough, and is right even for kinds the system has no name for (a .caf voice message).
        if let mime = mime?.lowercased() {
            if mime == "application/pdf" { return .pdf }
            if mime.hasPrefix("image/") { return .image }
            if mime.hasPrefix("video/") { return .video }
            if mime.hasPrefix("audio/") { return .audio }
        }
        let candidates: [UTType?] = [
            mime.flatMap { $0.isEmpty ? nil : UTType(mimeType: $0) },
            uti.flatMap { $0.isEmpty ? nil : UTType($0) },
            UTType(filenameExtension: (name as NSString).pathExtension),
        ]
        for case let type? in candidates {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .file
    }

    /// The preview line for a message that is only files ("Photo", "2 videos"), in place of the bare "Attachment".
    static func summary(_ attachments: [MessageAttachment]) -> String {
        guard let first = attachments.first else { return "Attachment" }
        if attachments.count == 1 {
            if first.isSticker { return "Sticker" }
            switch first.kind {
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return "Audio message"
            case .pdf: return "PDF"
            case .file: return "File"
            }
        }
        let count = attachments.count
        if attachments.allSatisfy({ $0.kind == first.kind }) {
            switch first.kind {
            case .image: return "\(count) photos"
            case .video: return "\(count) videos"
            case .audio: return "\(count) audio messages"
            case .pdf: return "\(count) PDFs"
            case .file: return "\(count) files"
            }
        }
        return "\(count) attachments"
    }
}

struct IncomingMessage: Equatable {
    let rowID: Int64
    let chatID: Int64
    let chatGUID: String
    let groupName: String
    let isGroup: Bool
    let senderHandle: String
    var text: String
    let date: Date
    /// The files that came with it, and whether `text` is only the stand-in for them ("Photo", "2 videos"...) rather than words.
    var attachments: [MessageAttachment] = []
    var textIsPlaceholder = false
}
