import SwiftUI

/// One module that lives inside the notch. Anything that can draw a view can be a widget.
struct NotchWidget: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let content: @MainActor () -> AnyView
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
        if NotchMessagesSettings.isEnabled {
            widgets.append(NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") {
                AnyView(MessagesWidgetView(store: MessagesStore.shared))
            })
        }
        return widgets
    }
}
