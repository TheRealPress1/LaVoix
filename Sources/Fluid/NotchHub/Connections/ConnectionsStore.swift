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
    private static let savedKey = "connections.lastItems"

    /// The last list myOS sent is kept, so the tab is full the moment the engine starts, before myOS has had a chance to send a fresh one.
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let raw = try? JSONSerialization.jsonObject(with: data) {
            self.items = ConnectorItem.parse(raw)
        }
    }

    func set(_ items: [ConnectorItem]) {
        guard items != self.items else { return }
        self.items = items
        let raw: [[String: Any]] = items.map { i in
            var d: [String: Any] = ["id": i.id, "title": i.title, "detail": i.detail, "broken": i.broken]
            if let a = i.actionID { d["action_id"] = a }
            if let l = i.actionLabel { d["action_label"] = l }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: raw) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
        NotchHubController.shared.model.setBadge("connections", items.filter(\.broken).count)
    }

    /// Badge for a list restored at launch.
    func restoreBadge() {
        NotchHubController.shared.model.setBadge("connections", self.items.filter(\.broken).count)
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

    @State private var hovered: String?

    var body: some View {
        let rows = self.rows
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
                Text("Your connections show up here once myOS is running.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let broken = rows.filter(\.broken)
            let healthy = rows.filter { !$0.broken }
            ScrollView(.vertical, showsIndicators: false) {
                // Nothing moves when you point at a logo: a connector that needs attention is a full-width row with its button, the working ones
                // are logos in a wrapping line, and the name and detail of the one under the pointer appear in a strip of fixed height below.
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(broken) { item in self.brokenRow(item) }
                    if !healthy.isEmpty {
                        ConnectionsFlow(spacing: 8) {
                            ForEach(healthy) { item in self.logo(item) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        self.detail(healthy.first { $0.id == self.hovered })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
        }
    }

    private func displayName(_ item: ConnectorItem) -> String {
        item.title.hasPrefix("Bank · ") ? String(item.title.dropFirst(7)) : item.title
    }

    private func badge(_ item: ConnectorItem) -> some View {
        ConnectorIconView(id: item.id, title: item.title, size: 36)
            .overlay(alignment: .bottomTrailing) {
                Circle().fill(item.broken ? Color.orange : Color.green).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
    }

    /// A working connector: just its logo, lit while the pointer is on it.
    private func logo(_ item: ConnectorItem) -> some View {
        self.badge(item)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(self.hovered == item.id ? 0.12 : 0.06)))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { self.hovered = item.id } else if self.hovered == item.id { self.hovered = nil }
            }
            .help(self.displayName(item))
    }

    /// The line under the logos: always the same height, so showing or hiding a name moves nothing.
    private func detail(_ item: ConnectorItem?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.map(self.displayName) ?? " ").font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(item?.detail ?? " ").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 6)
    }

    /// A connector that needs attention: always open, with its button.
    private func brokenRow(_ item: ConnectorItem) -> some View {
        HStack(spacing: 10) {
            self.badge(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.displayName(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
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
        .padding(.vertical, 6).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
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

/// Lays its children out left to right and wraps to a new line when the next one would not fit, so a child that grows pushes the ones after it along.
struct ConnectionsFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return self.arrange(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = self.arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + self.spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - self.spacing)
        }
        return (CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight), frames)
    }
}
