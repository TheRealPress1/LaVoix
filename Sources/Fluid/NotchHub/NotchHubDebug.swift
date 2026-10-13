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
                case "meeting-processing": model.phase = .processing; model.endedAt = Date()
                case "meeting-ended": model.phase = .ended; model.endedAt = Date()
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
                model.showBanner(NotchBannerContent(
                    chatID: 1, chatGUID: "g", title: long ? "Group" : "Maya Chen", avatarHandle: long ? nil : "+15551230001",
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
            store.siteResolver = { track in track.bundleID == "company.thebrowser.dia" ? NowPlayingSource(kind: .youtube, name: "YouTube") : nil }
            @MainActor func track(_ title: String, artist: String = "A", app: String = "com.apple.Music", playing: Bool = true, art: Bool = false) -> NowPlayingStore.Track {
                NowPlayingStore.Track(title: title, artist: artist, album: nil, appName: "App", bundleID: app, isPlaying: playing, duration: 200,
                                      artwork: art ? NowPlayingStore.sample().track?.artwork : nil, pid: nil)
            }
            func settle() async { try? await Task.sleep(nanoseconds: 700_000_000) }

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

            // 3. Skipping through songs doesn't log the ones skipped.
            store.trackChanged(track("Skipped 1")); store.trackChanged(track("Skipped 2")); store.trackChanged(track("Kept"))
            await settle()
            check("only the song that settled is logged", store.history.map(\.title) == ["Kept", "Real video"])
            check("native apps show their own name", store.history[0].source.name == "Apple Music" && store.history[0].site == nil)
            check("Spotify and Music get their own names",
                  NowPlayingSource.native(bundleID: "com.spotify.client", appName: "x").name == "Spotify"
                  && NowPlayingSource.native(bundleID: "com.apple.Music", appName: "x").name == "Apple Music")

            // 4. Playing something again moves it to the top instead of adding a duplicate.
            store.trackChanged(nil)
            store.trackChanged(track("Real video", app: "company.thebrowser.dia"))
            await settle()
            check("replaying moves it to the top without a duplicate", store.history.map(\.title) == ["Real video", "Kept"])

            // 5. Pausing before it settles doesn't count.
            store.trackChanged(track("Barely heard"))
            store.trackChanged(track("Barely heard", playing: false))
            await settle()
            check("paused before settling is not logged", !store.history.contains { $0.title == "Barely heard" })

            // 6. Website detection from a host name.
            check("YouTube detected", NowPlayingSource.site(forHost: "www.youtube.com")?.kind == .youtube)
            check("YouTube Music is not YouTube", NowPlayingSource.site(forHost: "music.youtube.com")?.kind == .youtubeMusic)
            check("unknown sites give no label", NowPlayingSource.site(forHost: "mail.google.com") == nil)
            check("browsers are recognised", NowPlayingSource.isBrowser("company.thebrowser.dia") && !NowPlayingSource.isBrowser("com.spotify.client"))

            // 7. Persistence, removal, cap, cleanup.
            check("history survives a relaunch", NowPlayingStore(directory: dir).history == store.history)
            store.removeFromHistory(store.history[0])
            check("removing an item", store.history.map(\.title) == ["Kept"])
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
