import AppKit
import Combine
import Foundation

/// WhatsApp from the notch: your latest chats and their messages (read from WhatsApp Desktop on this Mac, never kept), a search over myOS's people with a phone
/// number for anyone else, and sending through WhatsApp Desktop without it coming to the front.
@MainActor
final class WhatsAppStore: ObservableObject {
    static let shared = WhatsAppStore()

    /// Who a conversation is with: the name to show and the number WhatsApp finds them by.
    struct Target: Equatable {
        let name: String
        let phone: String
    }

    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    enum State: Equatable { case loading, ready, unavailable }

    @Published private(set) var recents: [WhatsAppChat] = []
    @Published private(set) var contacts: [FaceTimeContact] = []
    @Published private(set) var state: State = .loading
    @Published private(set) var selected: Target?
    @Published private(set) var thread: [WhatsAppMessage] = []
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
    private var latestSearch = 0

    /// The newest message time you have looked at, per number, kept in this app only: it clears the notch's unread dot for a chat you opened.
    private static let seenKey = "LaVoixNotchWhatsAppSeenUpTo"
    private var seenUpTo: [String: TimeInterval] = UserDefaults.standard.dictionary(forKey: "LaVoixNotchWhatsAppSeenUpTo") as? [String: Double] ?? [:]
    var persistsSeen = true

    /// How a message is actually sent. Tests replace this so no real message is ever sent.
    var sendHandler: (String, String) async throws -> Void = { text, handle in
        try await WhatsAppSender.send(text, toHandle: handle)
    }

    func hasUnread(_ chat: WhatsAppChat) -> Bool {
        chat.unread > 0 && (self.seenUpTo[chat.phone] ?? 0) < chat.lastDate.timeIntervalSince1970
    }

    func refreshRecents() {
        Task {
            let result = await Task.detached(priority: .userInitiated) { WhatsAppDatabase.recents() }.value
            if let result {
                self.recents = result
                if self.state != .ready { self.state = .ready }
                // Like Messages, a chat is always open: the latest one, until you pick another (looking at it this way does not count as reading it).
                if self.selected == nil, let first = result.first {
                    self.selected = Target(name: first.name, phone: first.phone)
                    self.refreshThread()
                }
            } else if self.recents.isEmpty {
                self.state = .unavailable
            }
        }
    }

    func search(_ query: String) {
        self.latestSearch += 1
        let ticket = self.latestSearch
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { self.contacts = []; return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { FaceTimeDatabase.read(query: query, limit: 60) }.value
            // A slower, older search never replaces a newer one.
            guard ticket == self.latestSearch, let result else { return }
            self.contacts = result.filter { WhatsAppSender.digits(of: $0.address) != nil }
        }
    }

    func open(chat: WhatsAppChat) {
        self.open(Target(name: chat.name, phone: chat.phone), lastDate: chat.lastDate)
    }

    func open(contact: FaceTimeContact) {
        guard let phone = WhatsAppSender.digits(of: contact.address) else { return }
        self.open(Target(name: contact.name, phone: phone), lastDate: self.recents.first { $0.phone == phone }?.lastDate)
    }

    private func open(_ target: Target, lastDate: Date?) {
        self.selected = target
        self.thread = []
        self.pending = []
        self.error = nil
        if let lastDate { self.markSeen(target.phone, upTo: lastDate) }
        self.refreshThread()
    }

    func refreshThread() {
        Task { await self.reloadThread() }
    }

    private func reloadThread() async {
        guard let target = self.selected else { return }
        let result = await Task.detached(priority: .userInitiated) { WhatsAppDatabase.thread(phone: target.phone) }.value
        guard self.selected == target, let result else { return }
        if result != self.thread { self.thread = result }
        if let last = result.last { self.markSeen(target.phone, upTo: last.date) }
    }

    private func markSeen(_ phone: String, upTo date: Date) {
        let stamp = date.timeIntervalSince1970
        guard (self.seenUpTo[phone] ?? 0) < stamp else { return }
        self.seenUpTo[phone] = stamp
        if self.persistsSeen { UserDefaults.standard.set(self.seenUpTo, forKey: Self.seenKey) }
        self.objectWillChange.send()
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = self.selected, !self.isSending else { return }
        self.error = nil
        self.isSending = true
        let bubble = Pending(text: trimmed)
        self.pending.append(bubble)
        Task {
            defer { self.isSending = false }
            do {
                try await self.sendHandler(trimmed, target.phone)
                // The send is only reported once WhatsApp's database shows the message, so the real bubble is there now and the temporary one can go.
                await self.reloadThread()
                self.pending.removeAll { $0.id == bubble.id }
            } catch {
                self.error = error.localizedDescription
                self.pending.removeAll { $0.id == bubble.id }
            }
        }
    }

    func openWhatsApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
