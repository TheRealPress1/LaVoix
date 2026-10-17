import Contacts
import Foundation

/// A person's card from your address book, for the profile in myOS: full name, the name you saved them under, organization,
/// every email and phone, and their photo. Looked up by the emails and phone numbers myOS already knows for them (never by
/// name, which is not an identity).
nonisolated protocol EngineContactsProviding: Sendable {
    func lookup(emails: [String], phones: [String]) async -> [String: Any]
}

nonisolated struct LiveEngineContacts: EngineContactsProviding {
    func lookup(emails: [String], phones: [String]) async -> [String: Any] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return ["found": false, "reason": "LaVoix doesn't have access to your contacts."] }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
            CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactThumbnailImageDataKey, CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        ].map { $0 as CNKeyDescriptor }
        let store = CNContactStore()
        var contact: CNContact?
        for email in emails.prefix(8) where contact == nil {
            contact = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: keys).first
        }
        for phone in phones.prefix(8) where contact == nil {
            contact = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone)), keysToFetch: keys).first
        }
        guard let c = contact else { return ["found": false] }
        var out: [String: Any] = [
            "found": true,
            "full_name": CNContactFormatter.string(from: c, style: .fullName) ?? "",
            "nickname": c.nickname, "organization": c.organizationName, "job_title": c.jobTitle,
            "emails": c.emailAddresses.map { String($0.value) },
            "phones": c.phoneNumbers.map { $0.value.stringValue },
        ]
        if let photo = c.thumbnailImageData { out["photo"] = photo.base64EncodedString() }
        return out
    }
}
