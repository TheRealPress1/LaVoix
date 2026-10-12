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
                model.showBanner(NotchBannerContent(
                    chatID: 1, chatGUID: "g", title: "Maya Chen", avatarHandle: "+15551230001", subtitle: nil,
                    text: "Are we still on for dinner tonight? I booked the place on 5th for 7:30 🍝", date: Date()
                ))
                model.setBannerExpanded(widgetName == "banner-expanded")
            } else if widgetName.hasPrefix("nowplaying") {
                let store = widgetName == "nowplaying-empty"
                    ? NowPlayingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-empty-\(UUID().uuidString)"))
                    : NowPlayingStore.sample(playing: widgetName != "nowplaying-paused")
                let showHistory = widgetName == "nowplaying-history"
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "nowplaying", title: "Now Playing", systemImage: "music.note") { AnyView(NowPlayingWidgetView(store: store, staticLayout: true, showHistory: showHistory)) },
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

            let db = MessagesDatabase()
            print("real database access: \(db.checkAccess())")
            if case .granted = db.checkAccess() {
                func ms(_ block: () -> Void) -> Int {
                    let start = DispatchTime.now().uptimeNanoseconds
                    block()
                    return Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                }
                var conversations: [MessageConversation] = []
                let listMs = ms { conversations = db.conversations(limit: 12) }
                var threadMs: [Int] = []
                for c in conversations { threadMs.append(ms { _ = db.messages(chatID: c.id, limit: 12) }) }
                print("real DB: conversation list \(listMs) ms; per-thread reads \(threadMs) ms (old switch cost ≈ list + one thread; new cost for a cached chat = 0 ms of database work)")
            }
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

    /// `LAVOIX_NOWPLAYING_HISTORY_AUTOTEST=1` checks the listening history (logging, de-duplication, cap, persistence)
    /// in a temporary folder.
    @MainActor static func nowPlayingHistoryAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOWPLAYING_HISTORY_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-test-\(UUID().uuidString)")
            let store = NowPlayingStore(directory: dir)
            @MainActor func track(_ title: String, artist: String = "A", art: Bool = false) -> NowPlayingStore.Track {
                NowPlayingStore.Track(title: title, artist: artist, album: nil, appName: "Music", bundleID: "com.apple.Music", isPlaying: true, duration: 200,
                                      artwork: art ? NowPlayingStore.sample().track?.artwork : nil)
            }
            store.record(track("One", art: true))
            check("logs a track", store.history.map(\.title) == ["One"])
            let oneID = store.history[0].id
            check("saves a thumbnail for artwork", store.thumbnail(for: store.history[0]) != nil)
            store.record(track("One"))
            check("same track again is not logged twice", store.history.count == 1)
            store.record(track("Two"))
            check("newest first", store.history.map(\.title) == ["Two", "One"])
            store.record(track("One"))
            check("a track coming back after another is logged again", store.history.map(\.title) == ["One", "Two", "One"])
            store.record(track("Same title", artist: "X")); store.record(track("Same title", artist: "Y"))
            check("same title by a different artist counts as new", store.history.count == 5)
            check("history survives a relaunch", NowPlayingStore(directory: dir).history == store.history)
            store.removeFromHistory(store.history[0])
            check("removing an item", store.history.count == 4)
            for i in 0..<130 { store.record(track("Song \(i)", art: i < 3)) }
            check("capped at \(NowPlayingStore.maxHistory)", store.history.count == NowPlayingStore.maxHistory)
            let jpgs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".jpg") } ?? []
            check("thumbnails of evicted items are deleted", jpgs.isEmpty)
            _ = oneID
            store.clearHistory()
            check("clear empties history", store.history.isEmpty && NowPlayingStore(directory: dir).history.isEmpty)
            try? FileManager.default.removeItem(at: dir)
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
