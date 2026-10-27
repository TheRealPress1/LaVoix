import AppKit
import Combine
import Foundation

/// WhatsApp from the notch: a name from myOS's people (only those with a phone number, because WhatsApp finds people by number), and what you sent them
/// during this run. Sent text is kept in memory only, never written down; the conversation itself stays in WhatsApp.
@MainActor
final class WhatsAppStore: ObservableObject {
    static let shared = WhatsAppStore()

    struct Sent: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let date: Date
    }

    enum State: Equatable { case loading, ready, unavailable }

    @Published private(set) var contacts: [FaceTimeContact] = []
    @Published private(set) var state: State = .loading
    @Published private(set) var selected: FaceTimeContact?
    @Published private(set) var sent: [String: [Sent]] = [:]
    @Published private(set) var isSending = false
    @Published private(set) var error: String?
    private var latest = 0

    /// How a message is actually sent. Tests replace this so no real message is ever sent.
    var sendHandler: (String, String) async throws -> Void = { text, handle in
        try await WhatsAppSender.send(text, toHandle: handle)
    }

    func search(_ query: String) {
        self.latest += 1
        let ticket = self.latest
        Task {
            let result = await Task.detached(priority: .userInitiated) { FaceTimeDatabase.read(query: query, limit: 60) }.value
            // A slower, older search never replaces a newer one.
            guard ticket == self.latest else { return }
            if let result {
                self.contacts = result.filter { WhatsAppSender.digits(of: $0.address) != nil }
                self.state = .ready
            } else {
                self.state = .unavailable
            }
        }
    }

    func open(_ contact: FaceTimeContact) {
        self.selected = contact
        self.error = nil
    }

    func close() {
        self.selected = nil
        self.error = nil
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let person = self.selected, !self.isSending else { return }
        self.error = nil
        self.isSending = true
        let sentItem = Sent(text: trimmed, date: Date())
        self.sent[person.id, default: []].append(sentItem)
        Task {
            defer { self.isSending = false }
            do {
                try await self.sendHandler(trimmed, person.address)
            } catch {
                self.error = error.localizedDescription
                self.sent[person.id]?.removeAll { $0.id == sentItem.id }
            }
        }
    }

    func openWhatsApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
