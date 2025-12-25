// Services/JourneyContactService.swift
import Foundation
import Contacts

public final class JourneyContactService {

    public static let shared = JourneyContactService()

    private let store = CNContactStore()

    private init() {}

    // MARK: - Permission

    public enum PermissionStatus {
        case authorized
        case denied
        case notDetermined
        case restricted
    }

    public var permissionStatus: PermissionStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestAccess() async -> Bool {
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            print("❌ Contact access request failed: \(error)")
            return false
        }
    }

    // MARK: - Fetch Contact

    /// Lädt CNContact anhand identifier
    public func fetchContact(identifier: String) -> CNContact? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor
        ]

        do {
            return try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
        } catch {
            print("❌ Failed to fetch contact: \(error)")
            return nil
        }
    }

    /// Sucht Kontakt nach Email
    public func findContact(byEmail email: String) -> CNContact? {
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return contacts.first
        } catch {
            print("❌ Failed to find contact by email: \(error)")
            return nil
        }
    }

    /// Sucht Kontakt nach Telefonnummer
    public func findContact(byPhone phone: String) -> CNContact? {
        let normalizedPhone = normalizePhoneNumber(phone)
        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: normalizedPhone))
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            return contacts.first
        } catch {
            print("❌ Failed to find contact by phone: \(error)")
            return nil
        }
    }

    // MARK: - Create JourneyContactRef

    /// Erstellt JourneyContactRef aus CNContact
    public func createContactRef(
        from contact: CNContact,
        nodeId: UUID,
        role: ContactRole? = nil,
        note: String? = nil
    ) -> JourneyContactRef {
        let displayName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .ifEmpty(contact.organizationName)

        let primaryEmail = contact.emailAddresses.first?.value as String?
        let primaryPhone = contact.phoneNumbers.first?.value.stringValue

        return JourneyContactRef(
            nodeId: nodeId,
            contactId: contact.identifier,
            displayName: displayName,
            email: primaryEmail,
            phone: primaryPhone,
            role: role,
            note: note
        )
    }

    // MARK: - Avatar

    /// Lädt Avatar-Bild für Kontakt
    public func avatar(for contactId: String?) -> Data? {
        guard let contactId = contactId,
              let contact = fetchContact(identifier: contactId) else {
            return nil
        }
        return contact.thumbnailImageData
    }

    // MARK: - Helpers

    private func normalizePhoneNumber(_ phone: String) -> String {
        phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }
}

// MARK: - String Extension

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
