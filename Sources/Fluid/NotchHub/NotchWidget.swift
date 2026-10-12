import SwiftUI

/// One module that lives inside the notch. Anything that can draw a view can be a widget.
struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let content: @MainActor () -> AnyView
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
        if NotchMessagesSettings.isEnabled {
            widgets.append(NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") {
                AnyView(MessagesWidgetView(store: MessagesStore.shared))
            })
        }
        return widgets
    }
}
