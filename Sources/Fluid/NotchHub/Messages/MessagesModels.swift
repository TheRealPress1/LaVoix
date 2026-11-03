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
