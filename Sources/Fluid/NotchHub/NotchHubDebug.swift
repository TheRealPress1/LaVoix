import SwiftUI

/// `LAVOIX_NOTCH_RENDER=<file.png>` renders the open notch to an image and exits. Used to check the design
/// without needing screen-capture permission.
enum NotchHubDebug {
    @MainActor static func renderIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LAVOIX_NOTCH_RENDER"] else { return }
        Task { @MainActor in
            let widgetName = ProcessInfo.processInfo.environment["LAVOIX_NOTCH_RENDER_WIDGET"] ?? "system"
            let model: NotchHubModel
            if widgetName.hasPrefix("banner") {
                NotchHubView.previewStatic = true
                model = NotchHubModel()
                model.showBanner(NotchBannerContent(
                    chatID: 1, chatGUID: "g", title: "Maya Chen", subtitle: nil,
                    text: "Are we still on for dinner tonight? I booked the place on 5th for 7:30 🍝", date: Date()
                ))
                model.setBannerExpanded(widgetName == "banner-expanded")
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
            controller.debugShowBanner(NotchBannerContent(chatID: 1, chatGUID: "g", title: "Maya Chen", subtitle: nil, text: "test", date: Date()))
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
