import AppKit
import SwiftUI

/// One module that lives inside the notch. Anything that can draw a view can be a widget.
struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// A brand's own icon for the tab (WhatsApp's), drawn instead of the symbol when set.
    var brandImage: NSImage? = nil
    /// The brand icon without its colour, shown while the tab is not the open one.
    var brandImageIdle: NSImage? = nil
    /// Something the tab puts on the right of the title band while it is the open tab (French's language choice).
    var headerAccessory: (@MainActor () -> AnyView)? = nil
    let content: @MainActor () -> AnyView
}

extension NotchWidget {
    /// The colour of this tab's icon while it is the open tab (every other tab's icon is grey). WhatsApp draws its own brand icon instead.
    var tint: Color {
        switch self.id {
        case "system": Color(red: 0.20, green: 0.78, blue: 0.35)
        case "nowplaying": Color(red: 1.00, green: 0.27, blue: 0.42)
        case "links": Color(red: 0.04, green: 0.52, blue: 1.00)
        case "calendar": Color(red: 0.96, green: 0.32, blue: 0.29)
        case "clipboard": Color(red: 1.00, green: 0.62, blue: 0.04)
        case "shelf": Color(red: 0.19, green: 0.69, blue: 0.78)
        case "download": Color(red: 1.00, green: 0.30, blue: 0.30)
        case "people": Color(red: 0.69, green: 0.32, blue: 0.87)
        case "facetime": Color(red: 0.20, green: 0.78, blue: 0.35)
        case "messages": Color(red: 0.20, green: 0.78, blue: 0.35)
        case "french": Color(red: 0.40, green: 0.50, blue: 1.00)
        default: Color.white
        }
    }
}

private struct NotchWidgetActiveKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while a widget is mounted but hidden behind the selected tab, so it can pause its timers.
    var notchWidgetActive: Bool {
        get { self[NotchWidgetActiveKey.self] }
        set { self[NotchWidgetActiveKey.self] = newValue }
    }
}

@MainActor
enum NotchWidgetRegistry {
    /// Widgets in tab order. New modules (music, calendar, messages, ...) are added here.
    static func all() -> [NotchWidget] {
        var widgets = [
            NotchWidget(id: "system", title: "System", systemImage: "gauge.with.dots.needle.33percent") {
                AnyView(SystemStatsWidgetView())
            },
        ]
        widgets.append(NotchWidget(id: "nowplaying", title: "Now Playing", systemImage: "music.note") {
            AnyView(NowPlayingWidgetView(store: NowPlayingStore.shared))
        })
        widgets.append(NotchWidget(id: "links", title: "Quick links", systemImage: "link") {
            AnyView(QuickLinksWidgetView(store: QuickLinksStore.shared))
        })
        if NotchCalendarSettings.isEnabled {
            widgets.append(NotchWidget(id: "calendar", title: "Calendar", systemImage: "calendar") {
                AnyView(CalendarWidgetView(store: CalendarStore.shared))
            })
        }
        if NotchClipboardSettings.isEnabled {
            widgets.append(NotchWidget(id: "clipboard", title: "Clipboard", systemImage: "doc.on.clipboard") {
                AnyView(ClipboardWidgetView(store: ClipboardStore.shared))
            })
        }
        if NotchShelfSettings.isEnabled {
            widgets.append(NotchWidget(id: "shelf", title: "Shelf", systemImage: "tray.fill") {
                AnyView(ShelfWidgetView(store: ShelfStore.shared))
            })
        }
        if NotchDownloaderSettings.isEnabled {
            widgets.append(NotchWidget(id: "download", title: "YouTube to MP3", systemImage: "arrow.down.circle") {
                AnyView(DownloaderWidgetView(downloader: YouTubeDownloader.shared))
            })
        }
        if PeopleDatabase.isAvailable {
            widgets.append(NotchWidget(id: "people", title: "People", systemImage: "person.2.fill") {
                AnyView(PeopleWidgetView(store: PeopleStore.shared))
            })
        }
        if PeopleDatabase.isAvailable {
            widgets.append(NotchWidget(id: "facetime", title: "FaceTime", systemImage: "video.fill") {
                AnyView(FaceTimeWidgetView(store: FaceTimeStore.shared))
            })
        }
        if NotchMessagesSettings.isEnabled {
            widgets.append(NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") {
                AnyView(MessagesWidgetView(store: MessagesStore.shared))
            })
        }
        if PeopleDatabase.isAvailable && WhatsAppSender.isAvailable {
            widgets.append(NotchWidget(id: "whatsapp", title: "WhatsApp", systemImage: "bubble.left.fill", brandImage: ConnectorIcon.whatsApp, brandImageIdle: ConnectorIcon.whatsAppGrey) {
                AnyView(WhatsAppWidgetView(store: WhatsAppStore.shared))
            })
        }
        if NotchFrenchSettings.isEnabled && PeopleDatabase.isAvailable {
            widgets.append(NotchWidget(id: "french", title: "Translate", systemImage: "globe") {
                AnyView(FrenchWidgetView(store: FrenchStore.shared))
            })
        }
        widgets.append(NotchWidget(id: "connections", title: "Connections", systemImage: "gearshape.fill") {
            AnyView(ConnectionsWidgetView(store: ConnectionsStore.shared, messages: MessagesStore.shared))
        })
        return widgets
    }
}
