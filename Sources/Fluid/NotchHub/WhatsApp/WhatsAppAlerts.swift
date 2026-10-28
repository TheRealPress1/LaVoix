import AppKit
import Foundation

/// Shows a card in the notch when someone writes to you on WhatsApp. It watches WhatsApp Desktop's own database on this Mac (read-only, a tiny query every
/// few seconds), so it only sees messages while WhatsApp Desktop is running. Muted chats, groups and old messages are left out.
enum NotchWhatsAppSettings {
    private static let alertsKey = "LaVoixNotchWhatsAppAlerts"

    /// Cards for new WhatsApp messages. On by default.
    static var alertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.alertsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.alertsKey) }
    }
}

@MainActor
final class WhatsAppAlerts {
    static let shared = WhatsAppAlerts()

    /// Called for each new message worth a card.
    var onIncoming: ((WhatsAppIncoming) -> Void)?
    private var task: Task<Void, Never>?
    private let interval: UInt64 = 3_000_000_000

    func start() {
        guard self.task == nil, WhatsAppSender.isAvailable else { return }
        self.task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        self.task?.cancel()
        self.task = nil
    }

    private func run() async {
        // Watch from now on: whatever arrived while this was not running is not news.
        var last: Int64?
        while last == nil, !Task.isCancelled {
            last = await Task.detached(priority: .utility) { WhatsAppDatabase.latestMessagePK() }.value
            if last == nil { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: self.interval)
            guard !Task.isCancelled, let from = last else { return }
            guard let result = await Task.detached(priority: .utility, operation: { WhatsAppDatabase.incomingSince(pk: from) }).value else { continue }
            last = max(from, result.newest)
            guard !result.messages.isEmpty else { continue }
            // New messages also change the chat list and its unread dots.
            WhatsAppStore.shared.refreshRecents()
            // With WhatsApp itself in front you are looking at the message.
            guard NotchWhatsAppSettings.alertsEnabled, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "net.whatsapp.WhatsApp" else { continue }
            for message in result.messages { self.onIncoming?(message) }
        }
    }
}
