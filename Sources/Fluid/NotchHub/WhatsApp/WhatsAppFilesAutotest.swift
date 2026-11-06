import AppKit
import Foundation
import UniformTypeIdentifiers

extension NotchHubDebug {
    /// `LAVOIX_WHATSAPP_FILES_AUTOTEST=1`: pictures, videos, stickers and documents in the WhatsApp tab, on a FAKE WhatsApp folder (WhatsApp's table layout, invented
    /// files) made for the test. WhatsApp's real database is never opened, so nothing of anyone's is read.
    @MainActor static func whatsAppFilesAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_WHATSAPP_FILES_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                print("\(ok ? "PASS" : "FAIL") \(name)")
            }
            func sqlite(_ database: String, _ sql: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [database, sql]
                try? process.run()
                process.waitUntilExit()
            }

            let dir = MessagesSampleFiles.makeDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let root = dir.appendingPathComponent("Message")
            let folder = root.appendingPathComponent("Media/15551230001@s.whatsapp.net/a/b")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let relative = "Media/15551230001@s.whatsapp.net/a/b/"

            // Invented files where WhatsApp keeps them. A JPEG is also saved under a name with no known extension (as a phone export might), a tiny
            // lossless WebP stands in for a sticker, and one picture sits OUTSIDE the media folder (nothing may reach it).
            let scene = MessagesSampleFiles.scene(width: 1600, height: 900, warm: true)
            MessagesSampleFiles.writeImage(scene, to: folder.appendingPathComponent("photo.jpg"), type: .jpeg)
            MessagesSampleFiles.writeImage(scene, to: folder.appendingPathComponent("photo2.jpg"), type: .jpeg)
            MessagesSampleFiles.writeImage(scene, to: folder.appendingPathComponent("caption.jpg"), type: .jpeg)
            MessagesSampleFiles.writeImage(scene, to: folder.appendingPathComponent("blob.bin"), type: .jpeg)
            MessagesSampleFiles.writeImage(scene, to: dir.appendingPathComponent("secret.jpg"), type: .jpeg)
            MessagesSampleFiles.writePDF(to: folder.appendingPathComponent("doc.pdf"))
            let videoWritten = await MessagesSampleFiles.writeVideo(to: folder.appendingPathComponent("clip.mp4"))
            try? Data("not really a document".utf8).write(to: folder.appendingPathComponent("notes.docx"))
            try? Data("not really audio".utf8).write(to: folder.appendingPathComponent("voice.opus"))
            let webp = Data(base64Encoded: "UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
            try? webp?.write(to: folder.appendingPathComponent("sticker.webp"))

            // The fake database. Message numbers: 1 text, 2 bare photo, 3 photo with a caption, 4 bare video (mine), 5 bare document named "Lease agreement 2026",
            // 6 photo whose text is encoded data, 7 photo with no media row (not downloaded), 8 photo whose file is gone, 9 sticker, 10 path that climbs out of the
            // media folder, 11 voice note, 12 absolute path, 13 document "Notes", 14 photo with an unknown extension. 20 to 27: one newest message per other chat.
            struct Row { let pk: Int, session: Int, mine: Bool, type: Int, text: String?, path: String?, title: String? }
            let encoded = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="
            let rows: [Row] = [
                Row(pk: 1, session: 1, mine: false, type: 0, text: "hello there", path: nil, title: nil),
                Row(pk: 2, session: 1, mine: false, type: 1, text: nil, path: relative + "photo.jpg", title: nil),
                Row(pk: 3, session: 1, mine: false, type: 1, text: "from the terrace", path: relative + "caption.jpg", title: nil),
                Row(pk: 4, session: 1, mine: true, type: 2, text: nil, path: relative + "clip.mp4", title: nil),
                Row(pk: 5, session: 1, mine: false, type: 8, text: nil, path: relative + "doc.pdf", title: "Lease agreement 2026"),
                Row(pk: 6, session: 1, mine: false, type: 1, text: encoded, path: relative + "photo2.jpg", title: nil),
                Row(pk: 7, session: 1, mine: false, type: 1, text: nil, path: nil, title: nil),
                Row(pk: 8, session: 1, mine: false, type: 1, text: nil, path: relative + "gone.jpg", title: nil),
                Row(pk: 9, session: 1, mine: false, type: 15, text: nil, path: relative + "sticker.webp", title: nil),
                Row(pk: 10, session: 1, mine: false, type: 1, text: nil, path: "../secret.jpg", title: nil),
                Row(pk: 11, session: 1, mine: false, type: 3, text: nil, path: relative + "voice.opus", title: nil),
                Row(pk: 12, session: 1, mine: false, type: 1, text: nil, path: "/etc/hosts", title: nil),
                Row(pk: 13, session: 1, mine: false, type: 8, text: nil, path: relative + "notes.docx", title: "Notes"),
                Row(pk: 14, session: 1, mine: false, type: 1, text: nil, path: relative + "blob.bin", title: nil),
                Row(pk: 20, session: 2, mine: false, type: 1, text: nil, path: relative + "photo.jpg", title: nil),
                Row(pk: 21, session: 3, mine: false, type: 1, text: "from the terrace", path: relative + "caption.jpg", title: nil),
                Row(pk: 22, session: 4, mine: false, type: 0, text: "see you at 7", path: nil, title: nil),
                Row(pk: 23, session: 5, mine: false, type: 1, text: nil, path: nil, title: nil),
                Row(pk: 24, session: 6, mine: false, type: 2, text: nil, path: relative + "clip.mp4", title: nil),
                Row(pk: 25, session: 7, mine: false, type: 15, text: nil, path: relative + "sticker.webp", title: nil),
                Row(pk: 26, session: 8, mine: false, type: 1, text: nil, path: relative + "gone.jpg", title: nil),
                Row(pk: 27, session: 9, mine: false, type: 8, text: nil, path: relative + "doc.pdf", title: "Contract"),
            ]
            func quoted(_ value: String?) -> String { value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
            let base = Date().timeIntervalSince1970 - 978_307_200 - 30
            func buildDatabase(at url: URL, withMedia: Bool) {
                var sql = """
                CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZCONTACTJID TEXT, ZPARTNERNAME TEXT, ZLASTMESSAGEDATE REAL, ZLASTMESSAGETEXT TEXT, ZUNREADCOUNT INTEGER, ZREMOVED INTEGER, ZARCHIVED INTEGER, ZHIDDEN INTEGER, ZLASTMESSAGE INTEGER);
                CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZMESSAGEDATE REAL, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER, ZTEXT TEXT);
                CREATE TABLE ZWACHATPUSHCONFIG (ZJID TEXT, ZMUTEDUNTIL REAL);

                """
                if withMedia { sql += "CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZMEDIALOCALPATH TEXT, ZTHUMBNAILLOCALPATH TEXT, ZTITLE TEXT);\n" }
                // The newest message of each chat.
                let newest: [Int: Int] = [1: 14, 2: 20, 3: 21, 4: 22, 5: 23, 6: 24, 7: 25, 8: 26, 9: 27]
                for session in 1...9 {
                    let last = newest[session]!
                    sql += "INSERT INTO ZWACHATSESSION VALUES (\(session), '1555123000\(session)@s.whatsapp.net', 'Chat \(session)', \(base + Double(last) * 0.01), NULL, 0, 0, 0, 0, \(last));\n"
                }
                for row in rows {
                    sql += "INSERT INTO ZWAMESSAGE VALUES (\(row.pk), \(row.session), \(base + Double(row.pk) * 0.01), \(row.mine ? 1 : 0), \(row.type), \(quoted(row.text)));\n"
                    if withMedia, let path = row.path { sql += "INSERT INTO ZWAMEDIAITEM VALUES (\(row.pk + 1000), \(row.pk), \(quoted(path)), NULL, \(quoted(row.title)));\n" }
                }
                sqlite(url.path, sql)
            }
            buildDatabase(at: dir.appendingPathComponent("ChatStorage.sqlite"), withMedia: true)
            let container = dir.path
            let phone = "15551230001"

            // The thread.
            let thread = WhatsAppDatabase.thread(phone: phone, in: container) ?? []
            func message(_ id: Int64) -> WhatsAppMessage? { thread.first { $0.id == id } }
            check("the thread loads, oldest first, with every message kind that is shown (voice note included)", thread.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
            check("a photo with no caption has its file and the stand-in word is marked as such", message(2)?.attachments.count == 1 && message(2)?.attachments.first?.kind == .image && message(2)?.textIsPlaceholder == true && message(2)?.text == "Photo"
                  && message(2)?.attachments.first?.path == root.path + "/" + relative + "photo.jpg")
            check("a photo with a caption keeps its caption beside the file", message(3)?.attachments.first?.kind == .image && message(3)?.text == "from the terrace" && message(3)?.textIsPlaceholder == false)
            check("a video is a video, and the file is in the media folder under Message", message(4)?.attachments.first?.kind == .video && message(4)?.isFromMe == true && message(4)?.textIsPlaceholder == true && message(4)?.text == "Video")
            check("a PDF document is shown as a page, under the name it was sent with (and keeps its extension)", message(5)?.attachments.first?.kind == .pdf && message(5)?.attachments.first?.name == "Lease agreement 2026.pdf" && message(5)?.text == "Document")
            check("another document is a labelled file, named with its extension", message(13)?.attachments.first?.kind == .file && message(13)?.attachments.first?.name == "Notes.docx")
            check("encoded data where words should be is not words: the file stands for the message", message(6)?.attachments.count == 1 && message(6)?.textIsPlaceholder == true && message(6)?.text == "Photo")
            check("a photo with no media row (not downloaded) stays the plain word Photo", message(7)?.attachments.isEmpty == true && message(7)?.text == "Photo" && message(7)?.textIsPlaceholder == false)
            check("a photo whose file is not on this Mac stays the plain word Photo", message(8)?.attachments.isEmpty == true && message(8)?.text == "Photo" && message(8)?.textIsPlaceholder == false)
            check("a sticker is a picture marked as a sticker", message(9)?.attachments.first?.isSticker == true && message(9)?.attachments.first?.kind == .image && message(9)?.text == "Sticker")
            check("a path that climbs out of the media folder, or starts at the root of the disk, is never used", message(10)?.attachments.isEmpty == true && message(12)?.attachments.isEmpty == true)
            check("a voice note and a text message have no file", message(11)?.attachments.isEmpty == true && message(11)?.text == "Voice note" && message(1)?.attachments.isEmpty == true && message(1)?.text == "hello there")
            check("a picture saved under an extension the system has no name for is still a photo", message(14)?.attachments.first?.kind == .image)
            check("reading again gives the same thread, so the tab does not redraw for nothing", (WhatsAppDatabase.thread(phone: phone, in: container) ?? []) == thread)

            // The older layout, with no media table: every message still loads, as the plain word.
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent("old"), withIntermediateDirectories: true)
            buildDatabase(at: dir.appendingPathComponent("old/ChatStorage.sqlite"), withMedia: false)
            let old = WhatsAppDatabase.thread(phone: phone, in: dir.appendingPathComponent("old").path) ?? []
            check("without the media table the thread still loads, with the plain words and no files", old.count == 14 && old.allSatisfy { $0.attachments.isEmpty } && old.first { $0.id == 2 }?.text == "Photo")

            // The list.
            let chats = WhatsAppDatabase.recents(in: container) ?? []
            func chat(_ number: Int) -> WhatsAppChat? { chats.first { $0.phone == "1555123000\(number)" } }
            check("the list has every chat", chats.count == 9)
            check("a chat whose newest message is a bare photo carries the file for the tiny picture, and still says Photo", chat(2)?.lastFile?.kind == .image && chat(2)?.lastText == "Photo")
            check("a chat whose newest message has a caption shows the caption and no tiny picture", chat(3)?.lastText == "from the terrace" && chat(3)?.lastFile == nil)
            check("a chat whose newest message is text has no tiny picture", chat(4)?.lastText == "see you at 7" && chat(4)?.lastFile == nil)
            check("a photo that is not downloaded has no tiny picture, and says Photo", chat(5)?.lastText == "Photo" && chat(5)?.lastFile == nil)
            check("a bare video carries its file and says Video", chat(6)?.lastFile?.kind == .video && chat(6)?.lastText == "Video")
            check("a bare sticker carries its file, marked as a sticker", chat(7)?.lastFile?.isSticker == true && chat(7)?.lastText == "Sticker")
            check("a file that is gone gives no tiny picture", chat(8)?.lastText == "Photo" && chat(8)?.lastFile == nil)
            check("a bare document carries its file under its name", chat(9)?.lastFile?.kind == .pdf && chat(9)?.lastFile?.name == "Contract.pdf" && chat(9)?.lastText == "Document")
            check("a chat whose newest message has encoded data shows its file too", chat(1)?.lastFile?.kind == .image)
            check("without the media table the list still loads, with the plain words", (WhatsAppDatabase.recents(in: dir.appendingPathComponent("old").path) ?? []).count == 9 && (WhatsAppDatabase.recents(in: dir.appendingPathComponent("old").path) ?? []).allSatisfy { $0.lastFile == nil })

            // The cards for new messages.
            let incoming = WhatsAppDatabase.incomingSince(pk: 0, in: container)?.messages ?? []
            func card(_ number: Int) -> WhatsAppIncoming? { incoming.first { $0.phone == "1555123000\(number)" } }
            check("a new photo with no caption brings its file and the word is only the stand-in", card(2)?.files.count == 1 && card(2)?.textIsPlaceholder == true && card(2)?.text == "Photo")
            check("a new photo with a caption brings its file and keeps the caption", card(3)?.files.count == 1 && card(3)?.textIsPlaceholder == false && card(3)?.text == "from the terrace")
            check("a new text message brings no file", card(4)?.files.isEmpty == true && card(4)?.textIsPlaceholder == false && card(4)?.text == "see you at 7")
            check("a new photo with no media row brings none and says Photo", card(5)?.files.isEmpty == true && card(5)?.text == "Photo")
            check("a card keeps a file that has not reached the disk yet, so its tile can keep looking", card(8)?.files.count == 1 && card(8)?.files.first?.exists == false)
            check("a new video and a new document bring theirs", card(6)?.files.first?.kind == .video && card(9)?.files.first?.kind == .pdf)

            // The pure rules.
            func make(_ type: Int32, _ path: String, title: String = "", requireFile: Bool = false) -> MessageAttachment? {
                WhatsAppDatabase.attachment(id: 1, messageType: type, localPath: path, title: title, root: "/x/Message", requireFile: requireFile)
            }
            check("an unknown extension takes the kind of the message: photo, sticker, video; a document stays a plain file", make(1, "a/b.zzz")?.kind == .image && make(15, "a/b.zzz")?.kind == .image && make(2, "a/b.zzz")?.kind == .video && make(8, "a/b.zzz")?.kind == .file)
            check("the extension wins over the message kind (a GIF sent as a video is still a video file)", make(1, "a/b.mp4")?.kind == .video && make(2, "a/b.jpg")?.kind == .image)
            check("no path, a blank path, a voice note, a location and a text message give no file", make(1, "") == nil && make(1, "   ") == nil && make(3, "a/b.opus") == nil && make(5, "a/b.jpg") == nil && make(0, "a/b.jpg") == nil)
            check("dots in a file name are fine, only a climbing path is refused", make(1, "a/b..c.jpg") != nil && make(1, "a/../b.jpg") == nil && make(1, "../b.jpg") == nil && make(1, "/abs/b.jpg") == nil)
            check("a document keeps the name it was sent with, adds the extension when it lacks it, and never keeps a folder in the name", make(8, "a/x1.docx", title: "Report")?.name == "Report.docx" && make(8, "a/x1.docx", title: "Report.docx")?.name == "Report.docx" && make(8, "a/x1.pdf", title: "../../Report")?.name == "Report.pdf" && make(8, "a/x1.pdf", title: "")?.name == "x1.pdf")
            check("only messages with a file are asked about", WhatsAppDatabase.isBareFile(code: 1, text: "") && !WhatsAppDatabase.isBareFile(code: 1, text: "hi") && !WhatsAppDatabase.isBareFile(code: 0, text: "") && !WhatsAppDatabase.isBareFile(code: 3, text: "") && WhatsAppDatabase.isBareFile(code: 2, text: encoded))

            // The pictures themselves, from files WhatsApp-style (no thumbnail columns: everything is made from the file).
            func picture(_ file: MessageAttachment?, _ pixels: Int) async -> NSImage? {
                guard let file else { return nil }
                return await MessageAttachmentImages.image(for: file, maxPixel: pixels)
            }
            let tile = await picture(message(2)?.attachments.first, MessageAttachmentImages.tilePixels)
            check("a photo's tile picture is made from the file, cut down to the tile size", tile.map { max($0.size.width, $0.size.height) <= CGFloat(MessageAttachmentImages.tilePixels) && max($0.size.width, $0.size.height) >= 180 } == true)
            let blobPicture = await picture(message(14)?.attachments.first, 100)
            check("a picture saved without a known extension is read", blobPicture != nil)
            let pagePicture = await picture(message(5)?.attachments.first, 100)
            check("a document that is a PDF shows its first page", pagePicture != nil)
            if videoWritten {
                let frame = await picture(message(4)?.attachments.first, 100)
                check("a video shows a frame of itself", frame != nil)
            } else { print("SKIP video could not be written on this Mac") }
            let stickerPicture = await picture(message(9)?.attachments.first, 100)
            check("a sticker (WebP) is read as a picture", stickerPicture != nil)
            let labelPicture = await picture(message(13)?.attachments.first, 100)
            check("a document with no page to show gives no picture (it is drawn as a label)", message(13)?.attachments.first != nil && labelPicture == nil)
            let missingPicture = await picture(MessageAttachment(id: 1, path: root.path + "/nowhere.jpg", name: "nowhere.jpg", kind: .image), 100)
            check("a file that is not there gives no picture, and stops nothing", missingPicture == nil)

            // Clicking a tile opens a copy that any app can open, named as the document was sent.
            if let page = message(5)?.attachments.first, let copy = AttachmentOpener.openableCopy(of: page) {
                check("clicking a document opens a copy of it, under its own name, and leaves WhatsApp's file alone", copy.lastPathComponent == "Lease agreement 2026.pdf" && FileManager.default.fileExists(atPath: copy.path) && copy.path != page.path && page.exists)
                try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            } else { check("clicking a document opens a copy of it", false) }

            print(failures == 0 ? "WHATSAPP FILES AUTOTEST ALL PASSED" : "WHATSAPP FILES AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
