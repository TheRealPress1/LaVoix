import AppKit
import SwiftUI

/// In settings: which calendars the notch shows, grouped by account, and a shortcut to add a Google account.
struct NotchCalendarPickerView: View {
    @ObservedObject var store: CalendarStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendars in the notch")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            if self.store.access != .granted {
                Text("Allow calendar access (open the Calendar tab in the notch and tap Allow access) to choose calendars.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else if self.store.calendars.isEmpty {
                Text("No calendars found.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                ForEach(self.accounts, id: \.self) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account)
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .textCase(.uppercase)
                        ForEach(self.store.calendars.filter { $0.account == account }) { calendar in
                            Toggle(isOn: Binding(
                                get: { !self.store.hiddenCalendarIDs.contains(calendar.id) },
                                set: { self.store.setCalendar(calendar.id, visible: $0) }
                            )) {
                                HStack(spacing: 7) {
                                    Circle().fill(calendar.color).frame(width: 9, height: 9)
                                    Text(calendar.title).font(self.theme.typography.body)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Add a Google account…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Refresh") { self.store.reload() }
            }
            .padding(.top, 2)
            Text("Add your Google account to Calendar in System Settings → Internet Accounts (turn on Calendars). Its events then appear in the notch with everything else, and a meeting that shows up in two accounts is listed once.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { self.store.reload() }
    }

    private var accounts: [String] {
        var seen: [String] = []
        for calendar in self.store.calendars where !seen.contains(calendar.account) { seen.append(calendar.account) }
        return seen
    }
}
