import Contacts
import CryptoKit
import Foundation

/// Hands the address book to myOS as a snapshot file in `<data>/inbox/contacts/`, which myOS turns into canonical
/// people (see myOS `docs/prds/80-engine-contract.md`). Read-only on the address book; it never asks for permission
/// itself (the Messages widget does), and does nothing unless the user turned sharing on.
nonisolated enum ContactsInboxExporter {
    struct Card: Codable, Equatable {
        var external_id: String
        var given: String?
        var family: String?
        var nickname: String?
        var organization: String?
        var emails: [String]
        var phones: [String]
    }

    private struct Snapshot: Codable {
        var schema = 1
        var source = "contacts"
        var generated_at: String
        var contacts: [Card]
    }

    static let lastHashKey = "ContactsInboxLastHash"
    static let keptSnapshots = 3

    static func card(from contact: CNContact) -> Card {
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return Card(
            external_id: contact.identifier,
            given: clean(contact.givenName),
            family: clean(contact.familyName),
            nickname: clean(contact.nickname),
            organization: clean(contact.organizationName),
            emails: contact.emailAddresses.map { String($0.value) }.compactMap(clean).sorted(),
            phones: contact.phoneNumbers.map { $0.value.stringValue }.compactMap(clean).sorted()
        )
    }

    /// Every contact on this Mac, or nil when Contacts access has not been granted.
    static func fetchCards() -> [Card]? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey,
        ].map { $0 as CNKeyDescriptor }
        var cards: [Card] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in cards.append(card(from: contact)) }
        return cards
    }

    /// Stable order and stable bytes, so an unchanged address book hashes the same every time.
    static func contentHash(_ cards: [Card]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(cards.sorted { $0.external_id < $1.external_id })) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "contacts-\(formatter.string(from: date)).json"
    }

    /// Writes a snapshot unless the address book is unchanged since the last one. Returns the file written, if any.
    @discardableResult
    static func write(
        cards: [Card], dataDirectory: URL, defaults: UserDefaults = .standard, now: Date = Date()
    ) throws -> URL? {
        let hash = contentHash(cards)
        if defaults.string(forKey: lastHashKey) == hash { return nil }
        let directory = dataDirectory.appendingPathComponent("inbox/contacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Snapshot(
            generated_at: formatter.string(from: now), contacts: cards.sorted { $0.external_id < $1.external_id }
        ))
        let name = fileName(for: now)
        let target = directory.appendingPathComponent(name)
        // Temp file in the same folder, then rename; the dot prefix and .tmp keep it from being read half-written.
        let temp = directory.appendingPathComponent(".\(name).tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        defaults.set(hash, forKey: lastHashKey)
        prune(directory: directory)
        return target
    }

    /// Only the newest few snapshots are kept; myOS reads the newest.
    static func prune(directory: URL, keep: Int = keptSnapshots) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("contacts-") && $0.hasSuffix(".json") }
            .sorted()
        for old in files.dropLast(keep) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
    }

    /// The myOS data folder: the one myOS records, or the parent of an overridden Brain folder.
    static func dataDirectory(brainOverride: String?) -> URL? {
        if let brainOverride, !brainOverride.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (brainOverride as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        return MeetingBrainExporter.myOSDataDirectory(bootstrapDatabase: MeetingBrainExporter.defaultBootstrapDatabase)
    }
}

/// Keeps the snapshot current while sharing is on: once shortly after launch and again whenever Contacts changes.
@MainActor
final class ContactsInboxScheduler {
    static let shared = ContactsInboxScheduler()

    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    func start() {
        guard self.observer == nil else { return }
        self.observer = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 15) }
        }
        self.schedule(after: 20)
    }

    func schedule(after seconds: Double) {
        self.pending?.cancel()
        self.pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.exportNow()
        }
    }

    func exportNow() {
        let settings = SettingsStore.shared
        guard settings.shareContactsWithMyOSEnabled,
              let data = ContactsInboxExporter.dataDirectory(brainOverride: settings.meetingBrainFolderOverride) else { return }
        Task.detached(priority: .utility) {
            guard let cards = ContactsInboxExporter.fetchCards() else { return }
            do {
                if let file = try ContactsInboxExporter.write(cards: cards, dataDirectory: data) {
                    DebugLogger.shared.info("Shared \(cards.count) contacts with myOS (\(file.lastPathComponent))", source: "ContactsInbox")
                }
            } catch {
                DebugLogger.shared.warning("Contacts export failed: \(error.localizedDescription)", source: "ContactsInbox")
            }
        }
    }
}
