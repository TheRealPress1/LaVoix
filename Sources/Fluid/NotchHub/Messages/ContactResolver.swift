import Combine
import Contacts
import Foundation

/// Turns phone numbers and emails from Messages into the names in your Contacts. Everything stays in memory.
@MainActor
final class ContactResolver: ObservableObject {
    static let shared = ContactResolver()

    /// Bumps when names finish loading so views refresh.
    @Published private(set) var version = 0
    private var names: [String: String] = [:]
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
            self.names = loaded
            self.loading = false
            self.version += 1
        }
    }

    func name(for handle: String) -> String? {
        self.names[Self.key(handle)]
    }

    /// Phone numbers compare on their last ten digits so "+1 (555) 123-0001" matches "5551230001".
    nonisolated static func key(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    private nonisolated static func loadAll() -> [String: String] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
        var result: [String: String] = [:]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? CNContactStore().enumerateContacts(with: request) { contact, _ in
            var name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if name.isEmpty { name = contact.nickname }
            if name.isEmpty { name = contact.organizationName }
            guard !name.isEmpty else { return }
            for phone in contact.phoneNumbers { result[Self.key(phone.value.stringValue)] = name }
            for email in contact.emailAddresses { result[Self.key(email.value as String)] = name }
        }
        return result
    }
}
