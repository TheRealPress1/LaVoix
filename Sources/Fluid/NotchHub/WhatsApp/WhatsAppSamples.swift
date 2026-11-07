import AppKit
import Foundation
import UniformTypeIdentifiers

/// Invented chats and files for the WhatsApp tab's stills. Nothing here is anyone's real message or file, and nothing reads WhatsApp's database.
enum WhatsAppSamples {
    /// A store showing invented chats whose latest messages are a photo, a video and a caption, and a thread with pictures, a video, a document and a
    /// photo that has not reached the Mac. `variant` is the still's name: "whatsapp-files" (photos and a video), "whatsapp-files-chips" (a caption, a
    /// document, a photo that is not downloaded) or "whatsapp-files-enlarged" (the photo enlarged) or "whatsapp-files-gif" (GIFs, one not downloaded). Returns the id of the landscape photo, for the enlarged view.
    @MainActor
    static func make(variant: String) -> (store: WhatsAppStore, enlargedFileID: Int64?) {
        let dir = MessagesSampleFiles.makeDirectory()
        let landscape = dir.appendingPathComponent("beach.png")
        let portrait = dir.appendingPathComponent("tall.png")
        let pdf = dir.appendingPathComponent("Lease agreement 2026.pdf")
        let video = dir.appendingPathComponent("clip.mp4")
        MessagesSampleFiles.writeImage(MessagesSampleFiles.scene(width: 1200, height: 800, warm: true), to: landscape, type: .png)
        MessagesSampleFiles.writeImage(MessagesSampleFiles.scene(width: 600, height: 900, warm: false), to: portrait, type: .png)
        MessagesSampleFiles.writePDF(to: pdf)
        // The video's picture is read up front, because a still can't wait for it.
        let done = DispatchSemaphore(value: 0)
        Task.detached { _ = await MessagesSampleFiles.writeVideo(to: video); done.signal() }
        done.wait()
        func file(_ id: Int64, _ url: URL, _ kind: MessageAttachment.Kind) -> MessageAttachment {
            MessageAttachment(id: id, path: url.path, name: url.lastPathComponent, kind: kind)
        }
        let beach = file(900, landscape, .image), tall = file(901, portrait, .image)
        let clip = file(902, video, .video), lease = file(903, pdf, .pdf)
        // The same short clip as a GIF (WhatsApp keeps GIFs as silent videos): a video tile with a "GIF" mark.
        let gif = MessageAttachment(id: 904, path: video.path, name: video.lastPathComponent, kind: .video, isGIF: true)
        let gifTwo = MessageAttachment(id: 905, path: video.path, name: video.lastPathComponent, kind: .video, isGIF: true)
        let ready = DispatchSemaphore(value: 0)
        Task.detached { _ = await MessageAttachmentImages.image(for: clip, maxPixel: MessageAttachmentImages.tilePixels); ready.signal() }
        ready.wait()

        let now = Date()
        func message(_ id: Int64, _ text: String, mine: Bool, _ files: [MessageAttachment] = [], bare: Bool = false) -> WhatsAppMessage {
            WhatsAppMessage(id: id, text: text, date: now.addingTimeInterval(-Double(1000 - id)), isFromMe: mine, attachments: files, textIsPlaceholder: bare)
        }
        func chat(_ id: Int64, _ name: String, _ phone: String, _ text: String, file: MessageAttachment? = nil, unread: Int = 0, minutesAgo: Double) -> WhatsAppChat {
            WhatsAppChat(id: id, name: name, phone: phone, lastText: text, lastDate: now.addingTimeInterval(-minutesAgo * 60), unread: unread, lastFile: file)
        }
        let chips = variant == "whatsapp-files-chips"
        let gifs = variant == "whatsapp-files-gif"
        let recents = gifs ? [
            chat(1, "Maya Chen", "15551230001", "GIF", file: gif, unread: 1, minutesAgo: 2),
            chat(2, "Krish Bhatia", "15551230004", "GIF", minutesAgo: 41),
            chat(3, "Aryan Shah", "15551230005", "Are we still on for Thursday?", minutesAgo: 190),
        ] : [
            chips ? chat(1, "Maya Chen", "15551230001", "Photo", unread: 1, minutesAgo: 2) : chat(1, "Maya Chen", "15551230001", "Photo", file: beach, unread: 1, minutesAgo: 2),
            chat(2, "Krish Bhatia", "15551230004", "Video", file: clip, minutesAgo: 41),
            chat(3, "Aryan Shah", "15551230005", "Are we still on for Thursday?", minutesAgo: 190),
        ]
        // whatsapp-emoji: a short, words-only chat, so the emoji row and the smiley beside the reply box fit in the still's fixed height.
        let thread: [WhatsAppMessage] = variant == "whatsapp-emoji"
            ? [message(910, "are you coming tonight?", mine: false), message(911, "yes! 7pm works", mine: true), message(912, "see you there", mine: false)]
            : gifs
            ? [message(910, "look at this", mine: false), message(911, "GIF", mine: false, [gif], bare: true), message(912, "GIF", mine: true, [gifTwo], bare: true), message(913, "GIF", mine: false)]
            : chips
            ? [message(910, "from the terrace", mine: false, [tall]), message(911, "Document", mine: true, [lease], bare: true), message(912, "Photo", mine: false)]
            : [message(910, "look at this", mine: false), message(911, "Photo", mine: false, [beach, tall], bare: true), message(912, "Video", mine: true, [clip, lease, tall], bare: true)]
        let store = WhatsAppStore()
        store.persistsSeen = false
        store.debugShow(recents: recents, thread: thread)
        return (store, variant == "whatsapp-files-enlarged" ? beach.id : nil)
    }
}
