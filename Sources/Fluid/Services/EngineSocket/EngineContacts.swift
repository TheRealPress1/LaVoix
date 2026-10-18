import Contacts
import Foundation

/// A person's card from your address book, for the profile in myOS: full name, the name you saved them under, organization,
/// every email and phone, their photo, and the details myOS turns into facts: birthday (month and day only, never the year), other
/// dates, city-level places (no street or postcode), relatives, and links including social profiles. Looked up by the emails and phone numbers myOS already knows for them (never by
/// name, which is not an identity).
nonisolated protocol EngineContactsProviding: Sendable {
    func lookup(emails: [String], phones: [String]) async -> [String: Any]
}

nonisolated struct LiveEngineContacts: EngineContactsProviding {
    func lookup(emails: [String], phones: [String]) async -> [String: Any] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return ["found": false, "reason": "LaVoix doesn't have access to your contacts."] }
        var keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor, CNContactDatesKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor, CNContactUrlAddressesKey as CNKeyDescriptor, CNContactSocialProfilesKey as CNKeyDescriptor,
        ]
        keys.append(CNContactFormatter.descriptorForRequiredKeys(for: .fullName))
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
        out.merge(EngineContactDetails.details(of: c)) { _, new in new }
        return out
    }
}

/// What a card holds beyond the basics, as plain JSON. Kept apart from the live lookup so it can be tested on a card built in memory.
nonisolated enum EngineContactDetails {
    static func details(of c: CNContact) -> [String: Any] {
        var out: [String: Any] = [:]
        if c.isKeyAvailable(CNContactBirthdayKey), let b = c.birthday, let m = b.month, let d = b.day, (1...12).contains(m), (1...31).contains(d) {
            out["birthday"] = ["month": m, "day": d] // the year is deliberately left out
        }
        if c.isKeyAvailable(CNContactDatesKey) {
            let dates: [[String: Any]] = c.dates.compactMap { item in
                let m = item.value.month, d = item.value.day
                guard m != NSDateComponentUndefined, d != NSDateComponentUndefined, (1...12).contains(m), (1...31).contains(d) else { return nil }
                return ["label": label(item.label), "month": m, "day": d]
            }
            if !dates.isEmpty { out["dates"] = dates }
        }
        if c.isKeyAvailable(CNContactPostalAddressesKey) {
            // city, state and country only: a street address is not needed and is not sent
            let places: [[String: Any]] = c.postalAddresses.compactMap { item in
                let a = item.value
                guard !a.city.isEmpty else { return nil }
                return ["label": label(item.label), "city": a.city, "state": a.state, "country": a.country]
            }
            if !places.isEmpty { out["addresses"] = places }
        }
        if c.isKeyAvailable(CNContactRelationsKey) {
            let relations: [[String: Any]] = c.contactRelations.compactMap { item in
                let name = item.value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : ["label": label(item.label), "name": name]
            }
            if !relations.isEmpty { out["relations"] = relations }
        }
        var urls: [String] = []
        if c.isKeyAvailable(CNContactUrlAddressesKey) { urls += c.urlAddresses.map { String($0.value) } }
        if c.isKeyAvailable(CNContactSocialProfilesKey) { urls += c.socialProfiles.map { $0.value.urlString }.filter { !$0.isEmpty } }
        if !urls.isEmpty { out["urls"] = urls }
        return out
    }

    /// "_$!<Sister>!$_" becomes "Sister"; a custom label stays as written.
    static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        return localized.isEmpty ? raw : localized
    }
}
