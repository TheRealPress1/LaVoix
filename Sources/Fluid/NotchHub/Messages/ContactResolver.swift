import AppKit
import Combine
import Contacts
import Foundation
import ImageIO

/// Turns phone numbers and emails from Messages into the names in your Contacts. Everything stays in memory.
@MainActor
final class ContactResolver: ObservableObject {
    static let shared = ContactResolver()

    /// Bumps when names finish loading so views refresh.
    @Published private(set) var version = 0
    /// Every contact with a phone number or email, for finding someone to message. The handle is in the form Messages sends to.
    struct Entry: Equatable { let name: String; let handle: String }
    private(set) var entries: [Entry] = []
    private var names: [String: String] = [:]
    private var contactIDs: [String: String] = [:]
    private var photos: [String: NSImage] = [:]
    private var photoMisses: Set<String> = []
    private var photoLoading: Set<String> = []
    /// The pictures myOS keeps for people who have none in Contacts, by the same keys. Contacts' own picture always wins over these.
    private var keptPhotos: [String: NSImage] = [:]
    private var keptMissAt: [String: Date] = [:]
    private var keptLoading: Set<String> = []
    /// How long before a handle with no kept picture is looked at again (myOS may have found one since).
    static let keptRetry: TimeInterval = 300
    private var loading = false

    func loadIfNeeded() {
        guard !self.loading, self.names.isEmpty else { return }
        self.loading = true
        Task {
            let store = CNContactStore()
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = try? await store.requestAccess(for: .contacts)
            }
            guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
                self.loading = false
                return
            }
            let loaded = await Task.detached(priority: .utility) { Self.loadAll() }.value
            self.names = loaded.names
            self.contactIDs = loaded.ids
            self.entries = loaded.entries
            // Misses recorded before the cards were known (no card id to ask Contacts about) are not misses.
            self.photoMisses.removeAll()
            self.keptMissAt.removeAll()
            self.loading = false
            self.version += 1
        }
    }

    /// Contacts whose name contains every word typed, or whose number contains the digits typed (three or more), best first.
    func search(_ query: String, limit: Int = 8) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let digits = query.filter(\.isNumber)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        var scored: [(Int, Entry)] = []
        for e in self.entries where seen.insert(e.handle).inserted {
            let name = e.name.lowercased()
            if words.allSatisfy({ name.contains($0) }) {
                scored.append((name.hasPrefix(words[0]) ? 0 : 1, e))
            } else if digits.count >= 3, e.handle.filter(\.isNumber).contains(digits) {
                scored.append((2, e))
            }
        }
        return scored.sorted { ($0.0, $0.1.name) < ($1.0, $1.1.name) }.prefix(limit).map(\.1)
    }

    /// The address Messages sends to for what was typed: a phone number as +country digits (ten digits are taken as US), an email as is.
    nonisolated static func sendableHandle(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("@") {
            let parts = t.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !t.contains(" ") ? t.lowercased() : nil
        }
        guard t.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) else { return nil }
        let digits = t.filter(\.isNumber)
        switch digits.count {
        case 10: return "+1" + digits
        case 11 where digits.hasPrefix("1"): return "+" + digits
        case 8...15 where t.hasPrefix("+"): return "+" + digits
        default: return nil
        }
    }

    func name(for handle: String) -> String? {
        self.names[Self.key(handle)]
    }

    /// The person's picture: the one on their Contacts card, else the one myOS has kept for them (found through LinkedIn or Gravatar, for people the address book
    /// has no picture of). Pictures are fetched the first time they're needed, kept only in memory, and the view refreshes when one arrives.
    func photo(for handle: String) -> NSImage? {
        let key = Self.key(handle)
        if let image = self.photos[key] { return image }
        let contactID = self.contactIDs[key]
        if let contactID, !self.photoMisses.contains(key), !self.photoLoading.contains(key) {
            self.photoLoading.insert(key)
            Task {
                let data = await Task.detached(priority: .utility) { () -> Data? in
                    let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor]
                    return try? CNContactStore().unifiedContact(withIdentifier: contactID, keysToFetch: keys).thumbnailImageData
                }.value
                self.photoLoading.remove(key)
                if let data, let image = NSImage(data: data) { self.photos[key] = image } else { self.photoMisses.insert(key) }
                self.version += 1
            }
        }
        if let kept = self.keptPhotos[key] { return kept }
        self.loadKeptPhoto(key: key, contactID: contactID)
        return nil
    }

    /// Looks for myOS's picture of the person behind `key`, once (and again after a few minutes if there was none).
    private func loadKeptPhoto(key: String, contactID: String?) {
        guard !key.isEmpty, !self.keptLoading.contains(key) else { return }
        if let missed = self.keptMissAt[key], Date().timeIntervalSince(missed) < Self.keptRetry { return }
        guard PeopleDatabase.isAvailable else { return }
        self.keptLoading.insert(key)
        Task {
            let data = await Task.detached(priority: .utility) { () -> Data? in
                PeopleDatabase.photoFile(forHandle: key, contactID: contactID).flatMap { ContactResolver.avatarData(at: $0) }
            }.value
            self.keptLoading.remove(key)
            if let data, let image = NSImage(data: data) {
                self.keptPhotos[key] = image
                self.keptMissAt[key] = nil
                self.version += 1
            } else {
                self.keptMissAt[key] = Date()
            }
        }
    }

    /// A picture file scaled down to avatar size (a few hundred pixels at most), as PNG data, so forty headshots do not sit in memory at full size.
    nonisolated static func avatarData(at url: URL, maxPixels: Int = 192) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// Preview support: pretend this handle has a name.
    func debugSetName(_ name: String, for handle: String) {
        self.names[Self.key(handle)] = name
        self.version &+= 1
    }

    /// Preview support: pretend this handle has a photo.
    func debugSetPhoto(_ image: NSImage, for handle: String) {
        self.photos[Self.key(handle)] = image
    }

    /// Phone numbers compare on their last ten digits so "+1 (555) 123-0001" matches "5551230001".
    nonisolated static func key(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    private nonisolated static func loadAll() -> (names: [String: String], ids: [String: String], entries: [Entry]) {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        var result: [String: String] = [:]
        var ids: [String: String] = [:]
        var entries: [Entry] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            var name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = contact.nickname }
            if name.isEmpty { name = contact.organizationName }
            guard !name.isEmpty else { return }
            for phone in contact.phoneNumbers {
                if let handle = Self.sendableHandle(phone.value.stringValue) { entries.append(Entry(name: name, handle: handle)) }
                result[Self.key(phone.value.stringValue)] = name
                ids[Self.key(phone.value.stringValue)] = contact.identifier
            }
            for email in contact.emailAddresses {
                if let handle = Self.sendableHandle(email.value as String) { entries.append(Entry(name: name, handle: handle)) }
                result[Self.key(email.value as String)] = name
                ids[Self.key(email.value as String)] = contact.identifier
            }
        }
        return (result, ids, entries)
    }
}
