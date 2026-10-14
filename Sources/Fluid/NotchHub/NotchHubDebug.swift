import CryptoKit
import SwiftUI

/// `LAVOIX_NOTCH_RENDER=<file.png>` renders the open notch to an image and exits. Used to check the design
/// without needing screen-capture permission.
enum NotchHubDebug {
    @MainActor static func renderIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LAVOIX_NOTCH_RENDER"] else { return }
        Task { @MainActor in
            let widgetName = ProcessInfo.processInfo.environment["LAVOIX_NOTCH_RENDER_WIDGET"] ?? "system"
            if widgetName.hasPrefix("meeting") {
                let model = NotchMeetingModel()
                model.event = CalendarStore.sample().events.first
                model.startedAt = Date().addingTimeInterval(-754)
                model.sourceName = "Zoom"
                model.caption = "…so let's move the launch to the 14th and I'll send the revised plan tonight."
                switch widgetName {
                case "meeting-listening": model.caption = ""
                case "meeting-starting": model.phase = .starting
                case "meeting-detected", "meeting-detected-starting", "meeting-detected-error":
                    model.phase = .detected
                    model.detectedName = "Zoom · in Google Chrome"
                    model.detectedIcon = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
                    model.detectedStarting = widgetName.hasSuffix("starting")
                    model.detectedError = widgetName.hasSuffix("error") ? "Zoom is no longer available to record." : nil
                case "meeting-processing": model.phase = .processing; model.endedAt = Date()
                case "meeting-ended": model.phase = .ended; model.endedAt = Date()
                case "meeting-ended-writing": model.phase = .ended; model.endedAt = Date(); model.notes = .writing("Writing notes…")
                case "meeting-ended-ready": model.phase = .ended; model.endedAt = Date(); model.notes = .ready(UUID())
                case "meeting-failed": model.phase = .failed("Recording was interrupted. Your audio is saved.")
                default: break
                }
                // The clock ticks from `Date()`, so freeze it for a stable render.
                let view = NotchMeetingCardView(model: model, notchHeight: 32).padding(20).background(Color(white: 0.16))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("NOTCH RENDER WROTE \(path)")
                } else { print("NOTCH RENDER FAILED") }
                exit(0)
            }
            let model: NotchHubModel
            if widgetName.hasPrefix("banner") {
                NotchHubView.previewStatic = true
                if let stand_in = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil) {
                    ContactResolver.shared.debugSetPhoto(stand_in, for: "+15551230001")
                }
                model = NotchHubModel()
                let long = widgetName.contains("long")
                let text = long
                    ? "Aryan gaspard is going to be in Jersey next week and will come work w us for a day. He asked if we could also set up a time to grab dinner on Thursday after the office, maybe somewhere in Hoboken so it's easy for everyone to get to. Let me know what works and I'll send the invite round to the whole group this afternoon so nobody misses it"
                    : "Are we still on for dinner tonight? I booked the place on 5th for 7:30 🍝"
                ContactResolver.shared.debugSetName("Krish Bhatia", for: "+15551230004")
                ContactResolver.shared.debugSetName("Aryan Shah", for: "+15551230005")
                model.showBanner(NotchBannerContent(
                    chatID: 1, chatGUID: "g", title: long ? "Krish, Aryan +1" : "Maya Chen", avatarHandle: long ? nil : "+15551230001",
                    groupHandles: long ? ["+15551230004", "+15551230005", "+15551230006"] : [],
                    subtitle: long ? "Krish Bhatia" : nil, text: text, date: Date()
                ))
                model.setBannerExpanded(widgetName.hasSuffix("expanded"))
            } else if widgetName.hasPrefix("nowplaying") {
                let store = widgetName == "nowplaying-empty"
                    ? NowPlayingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-empty-\(UUID().uuidString)"))
                    : NowPlayingStore.sample(playing: widgetName != "nowplaying-paused")
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "nowplaying", title: "Now Playing", systemImage: "music.note") { AnyView(NowPlayingWidgetView(store: store, staticLayout: true)) },
                ])
                model.selectedWidgetID = "nowplaying"
            } else if widgetName.hasPrefix("download") {
                let downloader = YouTubeDownloader.sample(ready: widgetName != "download-setup", empty: widgetName == "download-empty")
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "download", title: "YouTube to MP3", systemImage: "arrow.down.circle") { AnyView(DownloaderWidgetView(downloader: downloader, staticLayout: true)) },
                ])
                model.selectedWidgetID = "download"
            } else if widgetName.hasPrefix("calendar") {
                let store: CalendarStore
                switch widgetName {
                case "calendar-empty": store = .sample(empty: true)
                case "calendar-denied": store = .sample(access: .denied)
                case "calendar-unknown": store = .sample(access: .unknown)
                default: store = .sample()
                }
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "calendar", title: "Calendar", systemImage: "calendar") { AnyView(CalendarWidgetView(store: store, staticLayout: true)) },
                ])
                model.selectedWidgetID = "calendar"
            } else if widgetName.hasPrefix("clipboard") || widgetName.hasPrefix("shelf") {
                let isClip = widgetName.hasPrefix("clipboard")
                let clip = widgetName == "clipboard-empty" ? ClipboardStore(pasteboard: NSPasteboard(name: NSPasteboard.Name("lavoix.empty")), directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) : ClipboardStore.sample()
                let shelf = widgetName == "shelf-empty" ? ShelfStore(indexURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")) : ShelfStore.sample()
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "clipboard", title: "Clipboard", systemImage: "doc.on.clipboard") { AnyView(ClipboardWidgetView(store: clip, staticLayout: true)) },
                    NotchWidget(id: "shelf", title: "Shelf", systemImage: "tray.fill") { AnyView(ShelfWidgetView(store: shelf, staticLayout: true)) },
                ])
                model.selectedWidgetID = isClip ? "clipboard" : "shelf"
            } else if widgetName.hasPrefix("messages") {
                let store = MessagesStore.sample(access: widgetName == "messages-denied" ? .needsFullDiskAccess : .granted)
                if widgetName == "messages-group" { store.select(5) }
                if let stand_in = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil) {
                    ContactResolver.shared.debugSetPhoto(stand_in, for: "+15551230001")
                    ContactResolver.shared.debugSetName("Krish Bhatia", for: "+15551230004")
                    ContactResolver.shared.debugSetName("Aryan Shah", for: "+15551230005")
                }
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") { AnyView(MessagesWidgetView(store: store, staticLayout: true)) },
                ])
                model.selectedWidgetID = "messages"
                model.setBadge("messages", 3)
            } else {
                model = NotchHubModel()
            }
            model.setClosedSize(CGSize(width: 190, height: 32))
            let view = NotchHubView(model: model, forceOpen: !widgetName.hasPrefix("banner"))
                .padding(20)
                .background(Color(white: 0.16))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:])
            {
                try? png.write(to: URL(fileURLWithPath: path))
                print("NOTCH RENDER WROTE \(path)")
            } else {
                print("NOTCH RENDER FAILED")
            }
            exit(0)
        }
    }

    /// `LAVOIX_MEETING_CARD_AUTOTEST=1` starts the hub, walks the meeting card through every phase, and checks that
    /// it hides while the hub is open.
    @MainActor static func meetingCardAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_MEETING_CARD_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            let hub = NotchHubController.shared
            let card = NotchMeetingCardController.shared
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            hub.debugIgnorePointer(true)
            hub.start()
            try? await Task.sleep(nanoseconds: 500_000_000)
            for (label, phase) in [("recording", NotchMeetingModel.Phase.recording), ("processing", .processing), ("ended", .ended), ("failed", .failed("x"))] {
                card.debugPresent(phase)
                try? await Task.sleep(nanoseconds: 400_000_000)
                out(card.debugReport(label))
            }
            // A "meeting starting" prompt must go away on its own even while the meeting coordinator keeps republishing
            // `idle`, and a message card must replace it instead of being swallowed.
            var event = CalendarStore.sample().events[0]
            event.start = Date()   // the prompt stays up until shortly after the meeting starts
            card.startingDismissSeconds = 0.6
            card.presentStarting(event)
            for _ in 0..<5 { card.apply(state: .idle); try? await Task.sleep(nanoseconds: 50_000_000) }
            out("starting prompt shown, idle republished: showing=\(card.isShowing) (expect true)")
            hub.debugShowBanner(NotchBannerContent(chatID: 1, chatGUID: "g", title: "Maya", subtitle: nil, text: "hi", date: Date()))
            out("message arrives over the prompt: banner=\(hub.model.banner != nil) prompt still showing=\(card.isShowing) (expect true, false)")
            hub.dismissBanner()
            card.presentStarting(event)
            for _ in 0..<5 { card.apply(state: .idle); try? await Task.sleep(nanoseconds: 50_000_000) }
            try? await Task.sleep(nanoseconds: 900_000_000)
            out("prompt goes away by itself despite idle republishes: showing=\(card.isShowing) (expect false)")
            // A detected call: the card shows on the notch, a message card replaces it, and withdrawing never touches a
            // recording card that took its place.
            let shown = card.presentDetected(icon: nil, name: "Zoom")
            out("detected card presented: \(shown) showing=\(card.isShowingDetected) (expect true, true)")
            card.updateDetected(starting: true, error: nil)
            for _ in 0..<5 { card.apply(state: .preparing(UUID())); try? await Task.sleep(nanoseconds: 30_000_000) }
            out("detected card survives preparing: showing=\(card.isShowingDetected) (expect true)")
            card.debugPresent(.recording)
            card.withdrawDetected()
            out("withdraw leaves a recording card alone: showing=\(card.isShowing) (expect true)")
            card.dismiss()
            card.debugPresent(.recording)
            hub.debugShowBanner(NotchBannerContent(chatID: 1, chatGUID: "g", title: "Maya", subtitle: nil, text: "hi", date: Date()))
            out("a live recording keeps message cards away: banner=\(hub.model.banner != nil) (expect false)")
            hub.dismissBanner()
            card.debugPresent(.recording)
            hub.debugSetOpen(true)
            try? await Task.sleep(nanoseconds: 800_000_000)
            out(card.debugReport("hub open (card should be hidden)"))
            hub.debugSetOpen(false)
            try? await Task.sleep(nanoseconds: 800_000_000)
            out(card.debugReport("hub closed (card should be back)"))
            card.dismiss()
            out(card.debugReport("dismissed"))
            hub.stop()
            out(card.debugReport("hub stopped"))
            out("MEETING CARD AUTOTEST DONE")
            exit(0)
        }
    }

    /// `LAVOIX_AUTONOTES_AUTOTEST=1` runs the after-meeting notes pipeline against a temporary meeting folder with a
    /// stand-in for the model: it checks the saved file matches what the notes screen reads, and that it stays quiet
    /// when auto-notes are off or the transcript is empty.
    @MainActor static func autoNotesAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_AUTONOTES_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                print("\(ok ? "PASS" : "FAIL") \(name)")
                if !ok { failures += 1 }
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-autonotes-\(UUID().uuidString)")
            let store = MeetingSessionStore(rootDirectory: root)
            let track = UUID()
            var session = MeetingSession(
                configuration: MeetingCaptureConfiguration(
                    mode: .inRoom, title: "Auto notes fixture", application: nil,
                    microphone: MeetingMicrophoneIdentity(captureDeviceID: "m", coreAudioUID: "m", displayName: "Mic")
                ),
                timebase: MeetingTimebaseMetadata(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
            )
            let empty = session
            session.transcriptSegments = [MeetingTranscriptSegment(
                id: UUID(), start: MeetingMediaTime(value: 0, timescale: 1), end: MeetingMediaTime(value: 4, timescale: 1),
                sourceTrackID: track, speakerID: nil, text: "We will ship on Thursday.", revision: 1,
                status: .final, overlap: .none, completeness: .complete
            )]
            do { try await store.create(empty) } catch { print("create failed:", error) }
            let service = MeetingAutoAnalysis.shared
            service.store = store
            service.generatorOverride = { _, _ in "- Ship on Thursday." }
            @MainActor func settle() async {
                for _ in 0..<100 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if case .writing = service.status { continue }
                    return
                }
            }
            SettingsStore.shared.meetingAutoNotesEnabled = true
            service.start(session: session)
            await settle()
            print("status:", service.status); check("status becomes ready", service.status == .ready(session.id))
            let dir = try? await store.existingSessionDirectory(for: session.id)
            let file = dir?.appendingPathComponent("manual-summary-executive.json")
            let saved = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(MeetingNotesViewModel.Saved.self, from: $0) }
            check("manual-summary-executive.json written with the notes", saved?.text == "- Ship on Thursday.")
            let transcript = MeetingSummaryInput.transcript(for: session)
            check("fingerprint matches the notes screen's stale check",
                  saved?.transcriptHash == MeetingNotesViewModel.fingerprint(transcript: transcript, notes: ""))

            if let file { try? FileManager.default.removeItem(at: file) }
            SettingsStore.shared.meetingAutoNotesEnabled = false
            service.start(session: session)
            await settle()
            check("off: stays idle and writes nothing", service.status == .idle && !(file.map { FileManager.default.fileExists(atPath: $0.path) } ?? true))
            SettingsStore.shared.meetingAutoNotesEnabled = true

            service.start(session: empty)
            await settle()
            check("empty transcript: stays idle", service.status == .idle)

            service.generatorOverride = { _, _ in throw MeetingNotesError.emptyOutput }
            service.start(session: session)
            await settle()
            if case .failed = service.status { check("model failure surfaces as failed", true) } else { check("model failure surfaces as failed", false) }

            try? FileManager.default.removeItem(at: root)
            print(failures == 0 ? "AUTONOTES AUTOTEST ALL PASSED" : "AUTONOTES AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `LAVOIX_CLIPBOARD_AUTOTEST=1` exercises the clipboard and shelf stores against a private pasteboard and
    /// temporary folders, so it never touches the real clipboard.
    @MainActor static func clipboardAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_CLIPBOARD_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                print("\(ok ? "PASS" : "FAIL") \(name)")
                if !ok { failures += 1 }
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-clip-test-\(UUID().uuidString)")
            let pb = NSPasteboard(name: NSPasteboard.Name("lavoix.test.\(UUID().uuidString)"))
            let store = ClipboardStore(pasteboard: pb, directory: dir)

            pb.clearContents(); pb.setString("first", forType: .string); store.poll()
            check("records text", store.entries.first?.text == "first")

            pb.clearContents(); pb.setString("second", forType: .string); store.poll()
            check("newest first", store.entries.map(\.text) == ["second", "first"])

            pb.clearContents(); pb.setString("first", forType: .string); store.poll()
            check("duplicate moves to top, no copy", store.entries.map(\.text) == ["first", "second"])

            pb.clearContents()
            pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
            pb.setString("hunter2", forType: .string); store.poll()
            check("skips concealed (password manager) copies", !store.entries.contains { $0.text == "hunter2" })

            pb.clearContents(); pb.setString("   \n ", forType: .string); store.poll()
            check("skips whitespace-only", store.entries.count == 2)

            let image = NSImage(size: NSSize(width: 40, height: 40))
            image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); image.unlockFocus()
            pb.clearContents(); pb.writeObjects([image]); store.poll()
            check("records image with thumbnail", store.entries.first?.kind == .image && store.entries.first.flatMap { store.thumbnail(for: $0) } != nil)

            let file = dir.appendingPathComponent("note.txt"); try? "hi".write(to: file, atomically: true, encoding: .utf8)
            pb.clearContents(); pb.writeObjects([file as NSURL]); store.poll()
            check("records file copies", store.entries.first?.kind == .files && store.entries.first?.paths == [file.path])

            let target = store.entries.first { $0.text == "second" }!
            store.copy(target)
            check("copy puts text back on the pasteboard", pb.string(forType: .string) == "second")
            store.poll()
            check("our own copy is not recorded twice", store.entries.filter { $0.text == "second" }.count == 1 && store.entries.first?.text == "second")

            let reloaded = ClipboardStore(pasteboard: pb, directory: dir)
            check("history survives a relaunch", reloaded.entries.map(\.id) == store.entries.map(\.id))

            for i in 0..<60 { pb.clearContents(); pb.setString("item \(i)", forType: .string); store.poll() }
            check("history is capped at \(ClipboardStore.maxEntries)", store.entries.count == ClipboardStore.maxEntries)
            let pngs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".png") } ?? []
            check("evicted images are deleted from disk", pngs.isEmpty)

            store.clear()
            check("clear empties history", store.entries.isEmpty)

            let shelfIndex = dir.appendingPathComponent("shelf.json")
            let shelf = ShelfStore(indexURL: shelfIndex)
            shelf.add([file, file])
            check("shelf adds a file once", shelf.items.count == 1)
            check("shelf survives a relaunch", ShelfStore(indexURL: shelfIndex).items.count == 1)
            try? FileManager.default.removeItem(at: file)
            shelf.prune()
            check("shelf drops files that no longer exist", shelf.items.isEmpty)

            try? FileManager.default.removeItem(at: dir)
            print(failures == 0 ? "CLIPBOARD AUTOTEST ALL PASSED" : "CLIPBOARD AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `LAVOIX_MESSAGES_AUTOTEST=1` checks that switching conversations shows the cached thread immediately, and times
    /// the real database reads (read-only; message text is never printed).
    @MainActor static func messagesAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_MESSAGES_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            let store = MessagesStore.sample()
            let before = store.thread.map(\.id)
            store.select(2)
            print("\(store.selectedChatID == 2 && store.thread.map(\.id) == [10] ? "PASS" : "FAIL") switching to a cached chat shows its thread in the same tick (was \(before) now \(store.thread.map(\.id)))")
            store.select(1)
            print("\(store.thread.map(\.id) == before ? "PASS" : "FAIL") switching back restores the first thread")

            // Database failures must not look like "no conversations". A locked or unreadable database gives nil
            // (so the screen keeps what it has), while a readable empty one gives an empty list.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-db-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let dbURL = tmp.appendingPathComponent("chat.db")
            let schema = """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, display_name TEXT, chat_identifier TEXT, style INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, cache_has_attachments INTEGER, is_read INTEGER, item_type INTEGER, associated_message_type INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            """
            let create = Process()
            create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            create.arguments = [dbURL.path, schema]
            try? create.run(); create.waitUntilExit()
            let goodDB = MessagesDatabase(url: dbURL)
            print("\(goodDB.conversations(limit: 12)?.isEmpty == true ? "PASS" : "FAIL") a readable but empty database gives an empty list (not a failure)")
            let missing = MessagesDatabase(url: tmp.appendingPathComponent("nope.db"))
            print("\(missing.conversations(limit: 12) == nil && missing.messages(chatID: 1, limit: 12) == nil ? "PASS" : "FAIL") a missing database is a failure, not an empty list")
            let garbageURL = tmp.appendingPathComponent("garbage.db")
            try? Data("this is not a database at all, just text".utf8).write(to: garbageURL)
            print("\(MessagesDatabase(url: garbageURL).conversations(limit: 12) == nil ? "PASS" : "FAIL") an unreadable database is a failure, not an empty list")
            // Hold an exclusive lock on the file, as a busy Messages app might, and read at the same time.
            let locker = Process()
            locker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            locker.arguments = [dbURL.path]
            let lockInput = Pipe()
            locker.standardInput = lockInput
            locker.standardOutput = FileHandle.nullDevice
            try? locker.run()
            lockInput.fileHandleForWriting.write(Data("BEGIN EXCLUSIVE;\nSELECT 1;\n".utf8))
            try? await Task.sleep(nanoseconds: 500_000_000)
            let lockedResult = await Task.detached { goodDB.conversations(limit: 12) }.value
            print("\(lockedResult == nil ? "PASS" : "FAIL") a locked database is a failure, not an empty list")
            try? lockInput.fileHandleForWriting.close()
            locker.terminate()
            try? FileManager.default.removeItem(at: tmp)

            // Sending: the message must appear instantly, be replaced (not duplicated) when the database catches up,
            // and vanish if sending fails. A fake sender is used, so nothing is ever really sent.
            let sender = MessagesStore.sample()
            var sentCalls: [String] = []
            sender.sendHandler = { text, guid in
                sentCalls.append("\(guid):\(text)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            sender.select(3)
            sender.send("on my way")
            print("\(sender.thread.last?.text == "on my way" && (sender.thread.last?.id ?? 0) < 0 ? "PASS" : "FAIL") sent message appears in the thread immediately, before sending finishes")
            print("\(sender.conversations.first?.id == 3 && sender.conversations.first?.lastText == "on my way" && sender.conversations.first?.lastIsFromMe == true ? "PASS" : "FAIL") conversation preview updates and moves to the top immediately")
            try? await Task.sleep(nanoseconds: 100_000_000)
            print("\(sentCalls == ["g3:on my way"] ? "PASS" : "FAIL") the fake sender was called once for the right chat (real Messages untouched)")
            let countBefore = sender.thread.count
            let real = ThreadMessage(id: 500, text: "on my way", date: Date(), isFromMe: true, senderHandle: "")
            sender.apply(conversations: sender.conversations, threads: [3: sender.thread.filter { $0.id > 0 } + [real]], incoming: [], announce: false)
            print("\(sender.thread.count == countBefore && sender.thread.last?.id == 500 ? "PASS" : "FAIL") when the database shows it, the real message replaces the dimmed one with no duplicate")

            let failing = MessagesStore.sample()
            failing.sendHandler = { _, _ in throw MessagesSender.SendError.failed("nope") }
            failing.send("this will fail")
            print("\(failing.thread.last?.text == "this will fail" ? "PASS" : "FAIL") a message shows immediately even if it will fail")
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("\(failing.thread.last?.text != "this will fail" && failing.sendError != nil ? "PASS" : "FAIL") a failed send is removed and the error is shown")

            exit(0)
        }
    }

    /// `LAVOIX_CALENDAR_AUTOTEST=1` checks the calendar logic (call-link detection, which meeting to offer to record,
    /// labels) without touching EventKit, so it never triggers a permission prompt.
    @MainActor static func calendarAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_CALENDAR_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
            check("finds a Zoom link in notes", CalendarStore.joinURL(in: [nil, "Room 4", "Join: https://acme.zoom.us/j/123?pwd=x thanks"])?.host == "acme.zoom.us")
            check("finds a Meet link in the URL field", CalendarStore.joinURL(in: ["https://meet.google.com/abc-defg-hij", nil, nil])?.host == "meet.google.com")
            check("finds a Teams link", CalendarStore.joinURL(in: [nil, nil, "https://teams.microsoft.com/l/meetup-join/abc"]) != nil)
            check("ignores ordinary links", CalendarStore.joinURL(in: [nil, "https://example.com/agenda", "see https://notion.so/page"]) == nil)
            check("no link when there is no text", CalendarStore.joinURL(in: [nil, "", nil]) == nil)

            let now = Date()
            func event(_ id: String, start: Double, end: Double = 30, allDay: Bool = false, url: Bool = false, guests: Int = 0) -> CalendarStore.Event {
                CalendarStore.Event(id: id, title: id, start: now.addingTimeInterval(start * 60), end: now.addingTimeInterval((start + end) * 60), isAllDay: allDay, color: .blue, location: nil, joinURL: url ? URL(string: "https://zoom.us/j/1") : nil, attendeeCount: guests)
            }
            let call = event("call", start: 0.2, url: true)
            check("offers to record a call that is starting", CalendarStore.dueForPrompt(events: [call], now: now, prompted: []) == call)
            check("does not offer twice", CalendarStore.dueForPrompt(events: [call], now: now, prompted: ["call"]) == nil)
            check("not before it is about to start", CalendarStore.dueForPrompt(events: [event("later", start: 10, url: true)], now: now, prompted: []) == nil)
            check("a heads-up appears 2 minutes ahead", CalendarStore.dueForPrompt(events: [event("soon", start: 1.8, url: true)], now: now, prompted: []) != nil)
            check("but not 3 minutes ahead", CalendarStore.dueForPrompt(events: [event("notyet", start: 3, url: true)], now: now, prompted: []) == nil)
            check("countdown reads well", NotchMeetingCardView.countdown(to: now.addingTimeInterval(105), now: now) == "Starts in 1:45"
                  && NotchMeetingCardView.countdown(to: now.addingTimeInterval(-5), now: now) == "Starting now"
                  && NotchMeetingCardView.countdown(to: now.addingTimeInterval(-150), now: now) == "Started 2 min ago")
            check("still offers a few minutes after the start", CalendarStore.dueForPrompt(events: [event("late", start: -4, url: true)], now: now, prompted: []) != nil)
            check("not long after the start", CalendarStore.dueForPrompt(events: [event("old", start: -12, url: true)], now: now, prompted: []) == nil)
            check("skips solo events with no call link", CalendarStore.dueForPrompt(events: [event("gym", start: 0)], now: now, prompted: []) == nil)
            check("offers in-person meetings with guests", CalendarStore.dueForPrompt(events: [event("lunch", start: 0, guests: 3)], now: now, prompted: []) != nil)
            check("skips all-day events", CalendarStore.dueForPrompt(events: [event("holiday", start: 0, allDay: true, url: true)], now: now, prompted: []) == nil)

            let running = event("running", start: -10, end: 40)
            let next = event("next", start: 20)
            check("features the meeting in progress", CalendarStore.featured(from: [running, next], now: now) == running)
            check("features the next one when nothing is running", CalendarStore.featured(from: [next], now: now) == next)
            check("all-day events are never featured", CalendarStore.featured(from: [event("trip", start: -100, end: 2000, allDay: true)], now: now) == nil)

            check("label: now", CalendarStore.whenLabel(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(600), now: now) == "Now")
            check("label: minutes", CalendarStore.whenLabel(start: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(900 * 60), now: now) == "in 12 min")
            // Which calendars are fetched
            let names = ["iCloud", "Google", "Work"]
            check("nothing hidden asks for every calendar (nil), and that is not 'nothing to show'",
                  CalendarStore.visible(names, hidden: []) { $0 } == nil && !CalendarStore.nothingToShow(CalendarStore.visible(names, hidden: []) { $0 }))
            check("hiding one calendar leaves the others", CalendarStore.visible(names, hidden: ["Work"]) { $0 } == ["iCloud", "Google"])
            check("hiding every calendar means nothing to show", CalendarStore.nothingToShow(CalendarStore.visible(names, hidden: Set(names)) { $0 }))

            // Merging two accounts
            func dup(_ title: String, join: Bool = false, guests: Int = 0, cal: String) -> CalendarStore.Event {
                CalendarStore.Event(id: UUID().uuidString, title: title, start: now, end: now.addingTimeInterval(1800), isAllDay: false, color: .blue,
                                    location: nil, joinURL: join ? URL(string: "https://meet.google.com/abc-defg-hij") : nil, attendeeCount: guests, calendarTitle: cal)
            }
            let merged = CalendarStore.merged([dup("Standup", cal: "iCloud"), dup("standup", join: true, guests: 4, cal: "Google"), dup("Lunch", cal: "iCloud")])
            check("the same meeting in two accounts is listed once", merged.map(\.title).sorted() == ["Lunch", "standup"])
            check("the copy with the call link is the one kept", merged.first { $0.title.lowercased() == "standup" }?.joinURL != nil && merged.first { $0.title.lowercased() == "standup" }?.calendarTitle == "Google")
            let sameCount = CalendarStore.merged([dup("Sync", guests: 2, cal: "iCloud"), dup("Sync", guests: 5, cal: "Google")])
            check("with no link on either, the copy with more guests is kept", sameCount.count == 1 && sameCount[0].attendeeCount == 5)
            let differentTimes = CalendarStore.merged([dup("Gym", cal: "iCloud"), CalendarStore.Event(id: "x", title: "Gym", start: now.addingTimeInterval(86400), end: now.addingTimeInterval(88200), isAllDay: false, color: .blue, location: nil, joinURL: nil, attendeeCount: 0)])
            check("the same title at a different time is a different event", differentTimes.count == 2)

            // Month grid
            var cal = Calendar(identifier: .gregorian); cal.firstWeekday = 1
            let oct = DateComponents(calendar: cal, year: 2026, month: 10, day: 13).date!
            let octGrid = CalendarStore.gridDays(forMonth: oct, calendar: cal)
            check("October 2026 grid is whole weeks starting on Sunday", octGrid.count % 7 == 0 && cal.component(.weekday, from: octGrid[0]) == 1)
            check("October 2026 starts on Thursday so it leads with 4 days of September", cal.component(.month, from: octGrid[0]) == 9 && cal.component(.day, from: octGrid[0]) == 27 && octGrid.count == 35)
            let sepGrid = CalendarStore.gridDays(forMonth: DateComponents(calendar: cal, year: 2026, month: 8, day: 1).date!, calendar: cal)
            check("a month that spills into a sixth week gets six rows (August 2026)", sepGrid.count == 42)
            var mon = cal; mon.firstWeekday = 2
            check("grid honours a Monday week start", mon.component(.weekday, from: CalendarStore.gridDays(forMonth: oct, calendar: mon)[0]) == 2)
            check("start of month", cal.component(.day, from: CalendarStore.startOfMonth(oct, calendar: cal)) == 1)
            let day13 = cal.startOfDay(for: oct)
            func ev(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarStore.Event {
                CalendarStore.Event(id: id, title: id, start: start, end: end, isAllDay: allDay, color: .blue, location: nil, joinURL: nil, attendeeCount: 0)
            }
            let morning = ev("morning", day13.addingTimeInterval(9 * 3600), day13.addingTimeInterval(10 * 3600))
            let tomorrow = ev("tomorrow", day13.addingTimeInterval(33 * 3600), day13.addingTimeInterval(34 * 3600))
            let allDayTrip = ev("trip", day13.addingTimeInterval(-24 * 3600), day13.addingTimeInterval(48 * 3600), allDay: true)
            let overnight = ev("overnight", day13.addingTimeInterval(-3600), day13.addingTimeInterval(2 * 3600))
            let ends = ev("ends at midnight", day13.addingTimeInterval(-3600), day13)
            let onDay = CalendarStore.events(on: oct, in: [morning, tomorrow, allDayTrip, overnight, ends], calendar: cal).map(\.id)
            check("a day lists its own events, multi-day and overnight ones, but not the next day's", onDay == ["morning", "trip", "overnight"])
            check("an event ending exactly at midnight does not leak into the next day", !onDay.contains("ends at midnight"))
            check("label: hours", CalendarStore.whenLabel(start: now.addingTimeInterval(130 * 60), end: now.addingTimeInterval(900 * 60), now: now) == "in 2h 10m")
            print(failures == 0 ? "CALENDAR AUTOTEST ALL PASSED" : "CALENDAR AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `LAVOIX_NOTCH_TYPING_TEST=1` opens the notch on Messages (sample data), clicks the reply field with a synthetic
    /// mouse click, and reports whether the notch became the key window with a text editor focused, then types into it.
    @MainActor static func typingTestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOTCH_TYPING_TEST"] == "1" else { return }
        Task { @MainActor in
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            func fields(in view: NSView) -> [NSView] {
                var found: [NSView] = []
                if view is NSTextField || view is NSTextView { found.append(view) }
                for sub in view.subviews { found += fields(in: sub) }
                return found
            }
            @MainActor func state(_ label: String, _ window: NSWindow) {
                out("[\(label)] key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none") editing=\(NotchHubController.shared.isEditingText)")
            }
            let hub = NotchHubController.shared
            let store = MessagesStore.sample()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            hub.debugIgnorePointer(true)
            hub.start()
            hub.model.debugSetWidgets([
                NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") { AnyView(MessagesWidgetView(store: store)) },
            ])
            hub.debugSetOpen(true)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let window = hub.debugWindow, let content = window.contentView else { out("no window"); exit(1) }
            state("opened", window)
            let found = fields(in: content)
            out("text fields found: \(found.map { String(describing: type(of: $0)) })")
            guard let field = found.first else { out("TYPING TEST: no text field in the hierarchy"); exit(1) }
            let rect = field.convert(field.bounds, to: nil)
            let point = NSPoint(x: rect.midX, y: rect.midY)
            out("field frame in window: \(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)); window frame \(window.frame)")
            out("view under the click: \(content.hitTest(point).map { String(describing: type(of: $0)) } ?? "none")")
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                out("mouse event delivered: \(event.type == .leftMouseDown ? "down" : "up") window=\(event.window === window)")
                return event
            }
            _ = monitor
            // Click the middle of the reply capsule, a little left of the field's own bounds as a real click would land.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    // Queue it like a real click; handing a mouse-down straight to a text field blocks waiting for the mouse-up.
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            state("after click", window)
            if let editor = window.firstResponder as? NSTextView {
                editor.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
                out("typed text now reads: \"\(editor.string)\"")
                out("TYPING TEST: PASS")
            } else {
                out("TYPING TEST: FAIL (no text editor is first responder)")
            }
            hub.stop()
            exit(0)
        }
    }

    /// `LAVOIX_DOWNLOADER_AUTOTEST=1` checks the YouTube-to-MP3 tool with a fake yt-dlp (no network, nothing downloaded).
    @MainActor static func downloaderAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_DOWNLOADER_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
            let id = "aqz-KE-bpKQ"
            let canonical = URL(string: "https://www.youtube.com/watch?v=\(id)")
            /// Waits for something to become true (up to 5 s); the app is busy starting up when this test begins.
            @MainActor func until(_ condition: () -> Bool) async {
                for _ in 0..<100 {
                    if condition() { return }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            // Links
            check("a watch link", YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/watch?v=\(id)") == canonical)
            check("playlist and tracking parameters are dropped", YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/watch?v=\(id)&list=PLabc&index=3&si=xyz") == canonical)
            check("a short link", YouTubeDownloader.youTubeURL(from: "https://youtu.be/\(id)?si=abc") == canonical)
            check("a link with no scheme and spaces around it", YouTubeDownloader.youTubeURL(from: "  www.youtube.com/watch?v=\(id)  \n") == canonical)
            check("YouTube Music", YouTubeDownloader.youTubeURL(from: "https://music.youtube.com/watch?v=\(id)") == canonical)
            check("Shorts", YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/shorts/\(id)") == canonical)
            check("a half-typed or half-pasted link does not start anything", YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/watch?v=aqz-KE-bp") == nil && YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/watch?v=") == nil)
            check("not a video: the home page, a playlist, other sites, plain text",
                  YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/") == nil && YouTubeDownloader.youTubeURL(from: "https://www.youtube.com/playlist?list=PLabc") == nil
                  && YouTubeDownloader.youTubeURL(from: "https://vimeo.com/123456789") == nil && YouTubeDownloader.youTubeURL(from: "hello there") == nil
                  && YouTubeDownloader.youTubeURL(from: "https://evilyoutube.com/watch?v=\(id)") == nil)
            // Parsing
            check("progress lines", abs((YouTubeDownloader.progress(from: "LVP  45.3%") ?? 0) - 0.453) < 0.0001 && YouTubeDownloader.progress(from: "LVP 100.0%") == 1 && YouTubeDownloader.progress(from: "[download] 5%") == nil)
            let infoJSON = "{\"id\":\"\(id)\",\"title\":\"Big Buck Bunny\",\"channel\":\"Blender\",\"duration\":635,\"view_count\":23432904,\"license\":\"Creative Commons Attribution license (reuse allowed)\"}"
            let info = YouTubeDownloader.parseInfo(infoJSON)
            check("video details are read", info?.title == "Big Buck Bunny" && info?.channel == "Blender" && info?.duration == 635 && info?.viewCount == 23_432_904 && info?.videoID == id)
            check("Creative Commons is noticed", info?.isCreativeCommons == true && YouTubeDownloader.parseInfo("{\"title\":\"x\"}")?.isCreativeCommons == false)
            check("junk is not mistaken for details", YouTubeDownloader.parseInfo("not json") == nil)
            check("errors are made readable",
                  YouTubeDownloader.friendlyError("ERROR: [youtube] abc: Video unavailable") == "Video unavailable"
                  && YouTubeDownloader.friendlyError("ERROR: [youtube] abc: Sign in to confirm you’re not a bot").contains("sign-in")
                  && YouTubeDownloader.friendlyError(nil) == "The download didn't finish.")
            let args = YouTubeDownloader.downloadArguments(url: canonical!, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), folder: URL(fileURLWithPath: "/Users/me/Music/LaVoix"))
            check("MP3 arguments: one video, best-quality MP3, ffmpeg's folder, output in the chosen folder",
                  args.contains("--no-playlist") && args.contains("mp3") && args.contains("0") && args.contains("/opt/homebrew/bin")
                  && args.contains { $0.hasPrefix("/Users/me/Music/LaVoix/") } && args.last == canonical?.absoluteString)
            // Checksums
            let blob = Data("pretend this is yt-dlp".utf8)
            let sum = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            check("a download that matches the published checksum is accepted", YouTubeDownloader.verify(data: blob, sums: "deadbeef  other_file\n\(sum)  yt-dlp_macos\n", name: "yt-dlp_macos"))
            check("a download that doesn't match is refused", !YouTubeDownloader.verify(data: Data("tampered".utf8), sums: "\(sum)  yt-dlp_macos\n", name: "yt-dlp_macos"))
            check("a missing entry is refused", !YouTubeDownloader.verify(data: blob, sums: "\(sum)  something_else\n", name: "yt-dlp_macos"))
            // Finding tools
            let tools = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-dl-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            let fake = tools.appendingPathComponent("yt-dlp")
            try? "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
            check("a file that isn't executable is not a tool", YouTubeDownloader.firstExecutable([fake]) == nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            check("an executable file is found, in the order given", YouTubeDownloader.firstExecutable([URL(fileURLWithPath: "/nope/nope"), fake]) == fake)

            // A whole download with a fake yt-dlp
            let out = tools.appendingPathComponent("music")
            let downloader = YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support"))
            downloader.outputFolder = { out }
            downloader.debugSetTools(ytDlp: fake, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
            downloader.thumbnailFetcher = { _ in NowPlayingStore.sampleArtwork(wide: true) }
            let mp3 = out.appendingPathComponent("Big Buck Bunny.mp3")
            downloader.runner = { _, arguments in
                AsyncStream { continuation in
                    Task {
                        if arguments.contains("--dump-single-json") {
                            continuation.yield(.line("WARNING: noise before the JSON"))
                            continuation.yield(.line(infoJSON))
                            continuation.yield(.exit(0))
                        } else {
                            for line in ["LVP   0.0%", "LVP  42.0%", "LVP 100.0%", "[ExtractAudio] Destination: x.mp3", "LVFILE \(mp3.path)"] {
                                continuation.yield(.line(line)); try? await Task.sleep(nanoseconds: 30_000_000)
                            }
                            continuation.yield(.exit(0))
                        }
                        continuation.finish()
                    }
                }
            }
            check("a non-video link is refused without starting anything", !downloader.add("hello") && downloader.jobs.isEmpty)
            check("a video link starts a job", downloader.add("https://youtu.be/\(id)") && downloader.jobs.count == 1 && downloader.jobs[0].state == .fetching)
            await until { downloader.jobs[0].title == "Big Buck Bunny" }
            check("the job picks up the title and channel from the lookup", downloader.jobs[0].title == "Big Buck Bunny" && downloader.jobs[0].channel == "Blender" && downloader.jobs[0].isCreativeCommons)
            await until { downloader.jobs[0].state == .done }
            await until { downloader.jobs[0].thumbnail != nil }
            check("the job finishes with the file the tool reported", downloader.jobs[0].state == .done && downloader.jobs[0].file == mp3 && downloader.jobs[0].progress == 1)
            check("the thumbnail arrives", downloader.jobs[0].thumbnail != nil)
            // History survives a relaunch only for files that still exist
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? Data("mp3".utf8).write(to: mp3)
            downloader.remove(UUID()) // no-op, forces a save path to be exercised safely
            let reloaded = YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support"))
            check("finished downloads are remembered when the file is still there", reloaded.jobs.first?.title == "Big Buck Bunny" && reloaded.jobs.first?.state == .done)
            try? FileManager.default.removeItem(at: mp3)
            check("and forgotten when the file has gone", YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support")).jobs.isEmpty)

            // A failure, and a cancel
            let failing = YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support2"))
            failing.debugSetTools(ytDlp: fake, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
            failing.runner = { _, _ in AsyncStream { c in c.yield(.line("ERROR: [youtube] \(id): Private video")); c.yield(.exit(1)); c.finish() } }
            failing.add("https://youtu.be/\(id)")
            await until { failing.jobs[0].state != .fetching }
            check("a failed lookup shows the reason", failing.jobs[0].state == .failed("Private video"))

            let slow = YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support3"))
            slow.debugSetTools(ytDlp: fake, ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
            final class Stopped: @unchecked Sendable { var value = false }
            let stopped = Stopped()
            slow.runner = { _, _ in
                AsyncStream { c in
                    c.onTermination = { _ in stopped.value = true }
                    Task { try? await Task.sleep(nanoseconds: 5_000_000_000); c.yield(.exit(0)); c.finish() }
                }
            }
            slow.add("https://youtu.be/\(id)")
            try? await Task.sleep(nanoseconds: 150_000_000)
            slow.cancel(slow.jobs[0].id)
            await until { slow.jobs[0].state == .cancelled }
            await until { stopped.value }
            check("cancelling stops the tool and marks the job cancelled", slow.jobs[0].state == .cancelled && stopped.value)

            // Tools not ready
            let notReady = YouTubeDownloader(supportDirectory: tools.appendingPathComponent("support4"))
            notReady.debugSetTools(ytDlp: nil, ffmpeg: nil)
            check("nothing starts until both tools are there", !notReady.add("https://youtu.be/\(id)") && notReady.jobs.isEmpty)

            try? FileManager.default.removeItem(at: tools)
            print(failures == 0 ? "DOWNLOADER AUTOTEST ALL PASSED" : "DOWNLOADER AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `LAVOIX_DOWNLOADER_E2E=<youtube link>` runs one real download through the real yt-dlp and ffmpeg into a temporary
    /// folder, prints what happened, and deletes the file. Set `LAVOIX_YTDLP_PATH` to point at a yt-dlp.
    @MainActor static func downloaderE2EIfRequested() {
        guard let link = ProcessInfo.processInfo.environment["LAVOIX_DOWNLOADER_E2E"] else { return }
        Task { @MainActor in
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-dl-e2e-\(UUID().uuidString)")
            let downloader = YouTubeDownloader(supportDirectory: scratch.appendingPathComponent("support"))
            downloader.outputFolder = { scratch.appendingPathComponent("music") }
            out("tools: yt-dlp=\(downloader.ytDlp?.path ?? "none") ffmpeg=\(downloader.ffmpeg?.path ?? "none") ready=\(downloader.isReady)")
            guard downloader.add(link) else { out("E2E: link refused"); exit(1) }
            var seen: [String] = []
            let start = Date()
            while Date().timeIntervalSince(start) < 240 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let job = downloader.jobs.first else { break }
                let label = "\(job.state)" + (job.state == .downloading ? " \(Int(job.progress * 100))%" : "")
                if seen.last != label, seen.count < 40, !(job.state == .downloading && seen.last?.hasPrefix("downloading") == true && Int(job.progress * 100) % 25 != 0) { seen.append(label) }
                if !job.isRunning { break }
            }
            guard let job = downloader.jobs.first else { out("E2E: no job"); exit(1) }
            out("states seen: \(seen.joined(separator: " > "))")
            out("title=\(job.title) | channel=\(job.channel ?? "-") | views=\(job.viewCount.map(String.init) ?? "-") | CC=\(job.isCreativeCommons) | thumbnail=\(job.thumbnail != nil)")
            out("final state: \(job.state) in \(Int(Date().timeIntervalSince(start))) s")
            if let file = job.file {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                out("file: \(file.lastPathComponent) (\(size / 1024) KB) inside music folder: \(file.path.hasPrefix(scratch.appendingPathComponent("music").path))")
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
                probe.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_name:format_tags=title,artist", "-of", "default=nw=1", file.path]
                let pipe = Pipe(); probe.standardOutput = pipe
                try? probe.run(); probe.waitUntilExit()
                out("ffprobe: " + String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).replacingOccurrences(of: "\n", with: " | "))
            }
            try? FileManager.default.removeItem(at: scratch)
            out(job.state == .done ? "E2E: DONE" : "E2E: FAILED")
            exit(job.state == .done ? 0 : 1)
        }
    }

    /// `LAVOIX_NOTCH_LAG_TEST=1` opens the notch on each tab in turn (with sample data for every widget) and reports how long
    /// the main thread was blocked while it opened, and while the other tabs were being prepared right after.
    @MainActor static func lagTestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOTCH_LAG_TEST"] == "1" else { return }
        Task { @MainActor in
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            let hub = NotchHubController.shared
            let clipboard = ClipboardStore.sample()
            let shelf = ShelfStore.sample()
            let nowPlaying = NowPlayingStore.sample()
            let calendar = CalendarStore.sample()
            let messages = MessagesStore.sample()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            hub.debugIgnorePointer(true)
            hub.start()
            ContactResolver.shared.debugSetName("Krish Bhatia", for: "+15551230004")
            hub.model.debugSetWidgets([
                NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(SystemStatsWidgetView()) },
                NotchWidget(id: "nowplaying", title: "Now Playing", systemImage: "music.note") { AnyView(NowPlayingWidgetView(store: nowPlaying)) },
                NotchWidget(id: "calendar", title: "Calendar", systemImage: "calendar") { AnyView(CalendarWidgetView(store: calendar)) },
                NotchWidget(id: "clipboard", title: "Clipboard", systemImage: "doc.on.clipboard") { AnyView(ClipboardWidgetView(store: clipboard)) },
                NotchWidget(id: "shelf", title: "Shelf", systemImage: "tray.fill") { AnyView(ShelfWidgetView(store: shelf)) },
                NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") { AnyView(MessagesWidgetView(store: messages)) },
            ])
            try? await Task.sleep(nanoseconds: 800_000_000)
            if ProcessInfo.processInfo.environment["LAVOIX_NOTCH_LAG_PREWARM"] == "1" {
                SystemStatsSampler.prefetch()
                await hub.prewarmWidgets()
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            // Watches the main thread: a timer that should fire every few milliseconds; a long gap means it was blocked.
            final class Gaps: @unchecked Sendable { var last = DispatchTime.now().uptimeNanoseconds; var worst: Double = 0; var over16 = 0; var over50 = 0 }
            let gaps = Gaps()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(100))
            timer.setEventHandler {
                let now = DispatchTime.now().uptimeNanoseconds
                let gap = Double(now - gaps.last) / 1_000_000
                gaps.last = now
                gaps.worst = max(gaps.worst, gap)
                if gap > 16 { gaps.over16 += 1 }
                if gap > 50 { gaps.over50 += 1 }
            }
            timer.resume()
            for first in ["system", "nowplaying", "calendar", "messages"] {
                hub.debugSetOpen(false)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                hub.model.selectedWidgetID = first
                gaps.worst = 0; gaps.over16 = 0; gaps.over50 = 0; gaps.last = DispatchTime.now().uptimeNanoseconds
                hub.debugSetOpen(true)
                try? await Task.sleep(nanoseconds: 600_000_000)
                let opening = (gaps.worst, gaps.over16, gaps.over50)
                gaps.worst = 0; gaps.over16 = 0; gaps.over50 = 0
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                let after = (gaps.worst, gaps.over16, gaps.over50)
                out(String(format: "opening on %-10@ first 600 ms: worst stall %5.0f ms (%d over 16 ms, %d over 50 ms) | next 1.4 s while other tabs load: worst %5.0f ms (%d over 16 ms, %d over 50 ms)",
                           first as NSString, opening.0, opening.1, opening.2, after.0, after.1, after.2))
            }
            timer.cancel()
            hub.stop()
            out("LAG TEST DONE")
            exit(0)
        }
    }

    /// `LAVOIX_NOWPLAYING_HISTORY_AUTOTEST=1` checks the listening history (settling, merging, sources, cap, persistence)
    /// in a temporary folder.
    @MainActor static func nowPlayingHistoryAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOWPLAYING_HISTORY_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-test-\(UUID().uuidString)")
            let store = NowPlayingStore(directory: dir)
            store.settleDelay = 0.3
            store.siteResolver = { track in
                track.bundleID == "company.thebrowser.dia" ? NowPlayingStore.ResolvedSite(source: NowPlayingSource(kind: .youtube, name: "YouTube"), videoID: "dQw4w9WgXcQ") : nil
            }
            store.youTubeFetcher = { _ in NowPlayingArtwork.YouTubeInfo(viewCount: 1_234_567, thumbnail: NowPlayingStore.sampleArtwork(wide: true)) }
            @MainActor func track(_ title: String, artist: String = "A", app: String = "com.apple.Music", playing: Bool = true, art: Bool = false) -> NowPlayingStore.Track {
                NowPlayingStore.Track(title: title, artist: artist, album: nil, appName: "App", bundleID: app, isPlaying: playing, duration: 200,
                                      artwork: art ? NowPlayingStore.sample().track?.artwork : nil, pid: nil)
            }
            @MainActor func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }

            // 1. A title that flickers (the browser reporting another tab for a moment) is never logged.
            store.trackChanged(track("Real video", app: "company.thebrowser.dia"))
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.trackChanged(track("Gaspard Seuge", app: "company.thebrowser.dia"))
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.trackChanged(track("Real video", app: "company.thebrowser.dia"))
            try? await Task.sleep(nanoseconds: 100_000_000)
            store.trackChanged(track("Gaspard Seuge", app: "company.thebrowser.dia"))
            store.trackChanged(nil)
            await settle()
            check("flickering titles are not logged", store.history.isEmpty)

            // 2. A track that plays steadily is logged once, with its website.
            store.trackChanged(track("Real video", artist: "", app: "company.thebrowser.dia", art: true))
            store.trackChanged(track("Real video", artist: "SNL", app: "company.thebrowser.dia", art: true))
            await settle()
            check("a steady track is logged once", store.history.count == 1 && store.history[0].title == "Real video")
            check("artist filled in later is kept (artist ignored for matching)", store.history[0].artist == "SNL")
            check("website is recorded", store.history[0].site?.kind == .youtube && store.history[0].source.name == "YouTube")
            check("thumbnail saved", store.thumbnail(for: store.history[0]) != nil)

            check("YouTube video ID is kept", store.history[0].videoID == "dQw4w9WgXcQ")
            check("view count is kept", store.history[0].viewCount == 1_234_567)

            // 2b. A browser that hands over its own placeholder icon: the real YouTube thumbnail takes its place.
            func genericIcon() -> NSImage {
                // An image whose 8x8 fingerprint is exactly Chromium's default icon: one 8-pixel block per bit,
                // bright where the bit is set, row 0 at the top.
                let bits: UInt64 = 0xf7e1_fde4_e0f1_81c3
                let image = NSImage(size: NSSize(width: 64, height: 64))
                image.lockFocus()
                for row in 0..<8 { for col in 0..<8 {
                    let on = (bits >> UInt64(row * 8 + col)) & 1 == 1
                    (on ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.15, alpha: 1)).setFill()
                    NSRect(x: col * 8, y: (7 - row) * 8, width: 8, height: 8).fill()
                } }
                image.unlockFocus()
                return image
            }
            let placeholder = genericIcon()
            check("the placeholder icon is recognised as generic", NowPlayingArtwork.isGeneric(placeholder))
            check("real artwork is not mistaken for the placeholder", !NowPlayingArtwork.isGeneric(NowPlayingStore.sampleArtwork(wide: true)) && !NowPlayingArtwork.isGeneric(NowPlayingStore.sampleArtwork()))
            store.trackChanged(nil)
            var withPlaceholder = track("Another video", app: "company.thebrowser.dia")
            withPlaceholder.artwork = placeholder
            store.trackChanged(withPlaceholder)
            try? await Task.sleep(nanoseconds: 150_000_000)
            check("the placeholder is dropped and YouTube's thumbnail shown instead", store.track?.artwork != nil && !NowPlayingArtwork.isGeneric(store.track!.artwork!))
            check("view count shows on the playing track", store.track?.viewCount == 1_234_567)
            await settle()
            check("the logged entry gets the real thumbnail", store.history.first { $0.title == "Another video" }.flatMap { store.thumbnail(for: $0) } != nil)

            // 3. Skipping through songs doesn't log the ones skipped.
            store.trackChanged(track("Skipped 1")); store.trackChanged(track("Skipped 2")); store.trackChanged(track("Kept"))
            await settle()
            check("only the song that settled is logged", store.history.map(\.title) == ["Kept", "Another video", "Real video"])
            check("native apps show their own name", store.history[0].source.name == "Apple Music" && store.history[0].site == nil)
            check("Spotify and Music get their own names",
                  NowPlayingSource.native(bundleID: "com.spotify.client", appName: "x").name == "Spotify"
                  && NowPlayingSource.native(bundleID: "com.apple.Music", appName: "x").name == "Apple Music")

            // 4. Playing something again moves it to the top instead of adding a duplicate.
            store.trackChanged(nil)
            store.trackChanged(track("Real video", app: "company.thebrowser.dia"))
            await settle()
            check("replaying moves it to the top without a duplicate", store.history.map(\.title) == ["Real video", "Kept", "Another video"])

            // 5. Pausing before it settles doesn't count.
            store.trackChanged(track("Barely heard"))
            store.trackChanged(track("Barely heard", playing: false))
            await settle()
            check("paused before settling is not logged", !store.history.contains { $0.title == "Barely heard" })

            // 6. Website detection from a host name.
            check("YouTube detected", NowPlayingSource.site(forHost: "www.youtube.com")?.kind == .youtube)
            check("YouTube Music is not YouTube", NowPlayingSource.site(forHost: "music.youtube.com")?.kind == .youtubeMusic)
            check("unknown sites give no label", NowPlayingSource.site(forHost: "mail.google.com") == nil)
            check("video ID from a watch page", NowPlayingArtwork.youTubeVideoID(host: "www.youtube.com", path: "/watch", query: "v=dQw4w9WgXcQ&t=30s") == "dQw4w9WgXcQ")
            check("video ID from a short link", NowPlayingArtwork.youTubeVideoID(host: "youtu.be", path: "/dQw4w9WgXcQ", query: "") == "dQw4w9WgXcQ")
            check("video ID from a Shorts page", NowPlayingArtwork.youTubeVideoID(host: "youtube.com", path: "/shorts/dQw4w9WgXcQ", query: "") == "dQw4w9WgXcQ")
            check("no video ID on the YouTube home page or other sites", NowPlayingArtwork.youTubeVideoID(host: "www.youtube.com", path: "/", query: "") == nil && NowPlayingArtwork.youTubeVideoID(host: "vimeo.com", path: "/watch", query: "v=dQw4w9WgXcQ") == nil)
            check("view count is read from the page data", NowPlayingArtwork.viewCount(inPage: "x\"videoDetails\":{\"viewCount\":\"48210334\",\"author\":\"y\"}") == 48_210_334 && NowPlayingArtwork.viewCount(inPage: "nothing here") == nil)
            check("view counts read well", NowPlayingArtwork.viewsText(1_234_567) == "1.2M views" && NowPlayingArtwork.viewsText(48_210) == "48K views" && NowPlayingArtwork.viewsText(312) == "312 views" && NowPlayingArtwork.viewsText(1) == "1 view" && NowPlayingArtwork.viewsText(2_500_000_000) == "2.5B views")
            check("browsers are recognised", NowPlayingSource.isBrowser("company.thebrowser.dia") && !NowPlayingSource.isBrowser("com.spotify.client"))

            // 7. Persistence, removal, cap, cleanup.
            check("history survives a relaunch", NowPlayingStore(directory: dir).history == store.history)
            store.removeFromHistory(store.history[0])
            check("removing an item", store.history.map(\.title) == ["Kept", "Another video"])
            for i in 0..<130 { store.record(track("Song \(i)", art: i < 3)) }
            check("capped at \(NowPlayingStore.maxHistory)", store.history.count == NowPlayingStore.maxHistory)
            let jpgs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".jpg") } ?? []
            check("thumbnails of evicted items are deleted", jpgs.isEmpty)
            store.clearHistory()
            check("clear empties history", store.history.isEmpty && NowPlayingStore(directory: dir).history.isEmpty)

            // 8. Old junk (one entry per metadata flicker) is collapsed when loaded.
            let junkDir = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-junk-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: junkDir, withIntermediateDirectories: true)
            let now = Date().timeIntervalSinceReferenceDate
            func entry(_ title: String, _ artist: String, _ offset: Double) -> String {
                "{\"id\":\"\(UUID().uuidString)\",\"title\":\"\(title)\",\"artist\":\"\(artist)\",\"bundleID\":\"company.thebrowser.dia\",\"appName\":\"Dia\",\"date\":\(now - offset)}"
            }
            let junk = "[" + [entry("Video A", "", 10), entry("Video A", "Channel", 11), entry("Gaspard Seuge", "Channel", 12), entry("Video A", "", 13), entry("Video B", "X", 14)].joined(separator: ",") + "]"
            try? junk.write(to: junkDir.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
            let cleaned = NowPlayingStore(directory: junkDir)
            check("old duplicate entries are merged on load", cleaned.history.map(\.title) == ["Video A", "Gaspard Seuge", "Video B"])
            check("merging keeps the artist that was filled in", cleaned.history[0].artist == "Channel")

            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: junkDir)
            print(failures == 0 ? "NOWPLAYING HISTORY AUTOTEST ALL PASSED" : "NOWPLAYING HISTORY AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// `LAVOIX_NOWPLAYING_PROBE=1` starts the live MediaRemote listener for 6 seconds and prints what it reports.
    @MainActor static func nowPlayingProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOWPLAYING_PROBE"] == "1" else { return }
        Task { @MainActor in
            let store = NowPlayingStore.shared
            store.start()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if let t = store.track {
                print("NOWPLAYING PROBE: \(t.title) | \(t.artist ?? "-") | app=\(t.appName ?? "-") playing=\(t.isPlaying) duration=\(t.duration ?? 0) artwork=\(t.artwork != nil) elapsed=\(Int(store.elapsed))")
            } else {
                print("NOWPLAYING PROBE: no track reported")
            }
            store.stop()
            exit(0)
        }
    }

    /// `LAVOIX_NOTCH_AUTOTEST=1` starts the hub, opens and closes it, prints the window state, and exits.
    @MainActor static func autotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOTCH_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            let controller = NotchHubController.shared
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            controller.debugIgnorePointer(true)
            controller.start()
            try? await Task.sleep(nanoseconds: 800_000_000)
            out(controller.debugReport("started (closed)"))
            if let screen = NotchGeometry.targetScreen() {
                // A pointer against the very top of the screen must count as inside both regions.
                let edge = NSPoint(x: screen.frame.midX, y: screen.frame.maxY)
                out("top edge: inTrigger=\(NotchGeometry.triggerRect(for: screen).contains(edge)) inOpenRect=\(NotchGeometry.openRect(for: screen).contains(edge))")
            }
            controller.debugSetOpen(true)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            out(controller.debugReport("opened"))
            controller.debugSetOpen(false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            out(controller.debugReport("closed again"))
            controller.debugShowBanner(NotchBannerContent(chatID: 1, chatGUID: "g", title: "Maya Chen", avatarHandle: "+15551230001", subtitle: nil, text: "test", date: Date()))
            try? await Task.sleep(nanoseconds: 500_000_000)
            out(controller.debugReport("card shown") + " banner=\(controller.model.banner != nil) expanded=\(controller.model.bannerExpanded)")
            controller.debugSetBannerExpanded(true)
            controller.beginTextEntry()
            try? await Task.sleep(nanoseconds: 700_000_000)
            out(controller.debugReport("card expanded") + " banner=\(controller.model.banner != nil) expanded=\(controller.model.bannerExpanded)")
            controller.dismissBanner()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            out(controller.debugReport("card dismissed") + " banner=\(controller.model.banner != nil)")
            controller.stop()
            out(controller.debugReport("stopped"))
            out("NOTCH AUTOTEST DONE")
            exit(0)
        }
    }
}
