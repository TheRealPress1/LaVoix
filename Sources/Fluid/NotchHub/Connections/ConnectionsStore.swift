import AppKit
import Combine
import SwiftUI

/// One connector (a mailbox, Bump) as myOS last reported it, for the Connections tab.
struct ConnectorItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let broken: Bool
    /// What the button does (myOS runs it); nil when there is nothing to press.
    let actionID: String?
    let actionLabel: String?

    /// Items from the `notch.connections_set` request. Anything malformed is skipped.
    static func parse(_ raw: Any?) -> [ConnectorItem] {
        (raw as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
            return ConnectorItem(
                id: String(id.prefix(120)), title: String(title.prefix(80)), detail: String((d["detail"] as? String ?? "").prefix(200)),
                broken: d["broken"] as? Bool ?? false,
                actionID: (d["action_id"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(160)) },
                actionLabel: (d["action_label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }
            )
        }
    }
}

@MainActor
final class ConnectionsStore: ObservableObject {
    static let shared = ConnectionsStore()
    @Published private(set) var items: [ConnectorItem] = []

    func set(_ items: [ConnectorItem]) {
        guard items != self.items else { return }
        self.items = items
        NotchHubController.shared.model.setBadge("connections", items.filter(\.broken).count)
    }
}

/// The buttons pressed in the notch, waiting for myOS to pick them up. myOS asks with a long wait (`notch.action_wait`), so a press reaches it
/// at once without myOS having to be reachable from here.
actor ConnectionActions {
    static let shared = ConnectionActions()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var token = 0

    func push(_ id: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: id)
        } else {
            self.queue.append(id)
            if self.queue.count > 20 { self.queue.removeFirst() }
        }
    }

    /// The next pressed button, or nil after `timeout` seconds.
    func next(timeout: TimeInterval) async -> String? {
        if !self.queue.isEmpty { return self.queue.removeFirst() }
        if let old = self.waiter {
            self.waiter = nil
            old.resume(returning: nil)
        }
        self.token += 1
        let mine = self.token
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(mine)
            }
        }
    }

    private func expire(_ mine: Int) {
        guard mine == self.token, let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: nil)
    }
}

/// The Connections tab: every connector and whether it works, with a one-press Reconnect for the ones that don't.
struct ConnectionsWidgetView: View {
    @ObservedObject var store: ConnectionsStore
    @ObservedObject var messages: MessagesStore

    private static let fullDiskAccess = "local:full-disk-access"

    /// Messages is read by the engine itself, so its row is made here rather than sent by myOS.
    private var messagesItem: ConnectorItem? {
        guard NotchMessagesSettings.isEnabled else { return nil }
        switch self.messages.access {
        case .needsFullDiskAccess:
            return ConnectorItem(id: "messages", title: "Messages", detail: "Needs Full Disk Access to read your texts.", broken: true, actionID: Self.fullDiskAccess, actionLabel: "Open settings")
        case .granted where self.messages.loadFailed:
            return ConnectorItem(id: "messages", title: "Messages", detail: "Can't read your messages right now. It keeps trying.", broken: true, actionID: Self.fullDiskAccess, actionLabel: "Open settings")
        case .granted:
            return ConnectorItem(id: "messages", title: "Messages", detail: "Connected", broken: false, actionID: nil, actionLabel: nil)
        default:
            return nil
        }
    }

    private var rows: [ConnectorItem] {
        let all = [self.messagesItem].compactMap { $0 } + self.store.items
        return all.sorted { ($0.broken ? 0 : 1, $0.title) < ($1.broken ? 0 : 1, $1.title) }
    }

    var body: some View {
        let rows = self.rows
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
                Text("Your connections show up here once myOS is running.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(rows) { item in self.row(item) }
                }
            }
            .foregroundStyle(.white)
        }
    }

    private func row(_ item: ConnectorItem) -> some View {
        HStack(spacing: 10) {
            Circle().fill(item.broken ? Color.orange : Color.green.opacity(0.8)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let id = item.actionID, let label = item.actionLabel {
                Button { Self.press(id) } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.95)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    /// A button: the Full Disk Access one opens System Settings here; every other is handed to myOS.
    @MainActor static func press(_ id: String) {
        if id == self.fullDiskAccess {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
        } else {
            Task { await ConnectionActions.shared.push(id) }
        }
    }
}
