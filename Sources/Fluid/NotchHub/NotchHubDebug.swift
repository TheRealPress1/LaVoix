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
                model.startedAt = Date().addingTimeInterval(-754)
                model.sourceName = "Zoom"
                model.caption = "…so let's move the launch to the 14th and I'll send the revised plan tonight."
                switch widgetName {
                case "meeting-listening": model.caption = ""
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
                let store = widgetName == "nowplaying-empty" ? NowPlayingStore() : NowPlayingStore.sample(playing: widgetName != "nowplaying-paused")
                model = NotchHubModel(widgets: [
                    NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") { AnyView(EmptyView()) },
                    NotchWidget(id: "nowplaying", title: "Now Playing", systemImage: "music.note") { AnyView(NowPlayingWidgetView(store: store, staticLayout: true)) },
                ])
                model.selectedWidgetID = "nowplaying"
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
