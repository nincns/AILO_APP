import Foundation
import Security

/// Service für Zertifikat-Zugriff aus iOS-Schlüsselbund
class KeychainCertificateService {

    static let shared = KeychainCertificateService()

    private init() {}

    // MARK: - Zertifikate auflisten

    /// Listet alle S/MIME-fähigen Zertifikate (mit Private Key) aus dem Schlüsselbund
    func listSigningCertificates() -> [SigningCertificateInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                print("⚠️ [KeychainCertificate] Query failed: \(status)")
            }
            return []
        }

        return items.compactMap { parseIdentity($0) }
    }

    /// Parst eine Identity (Zertifikat + Private Key) zu Info-Objekt
    private func parseIdentity(_ attributes: [String: Any]) -> SigningCertificateInfo? {
        guard let identityRef = attributes[kSecValueRef as String] else { return nil }

        let identity = identityRef as! SecIdentity

        // Zertifikat extrahieren
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let certificate = certRef else { return nil }

        // Persistent Reference für Speicherung
        let persistentId = attributes[kSecAttrApplicationLabel as String] as? Data
        let idString = persistentId?.base64EncodedString() ?? UUID().uuidString

        // Zertifikat-Details extrahieren
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unbekannt"
        let email = extractEmail(from: certificate)
        let expiry = extractExpiry(from: certificate)

        return SigningCertificateInfo(
            id: idString,
            displayName: summary,
            email: email,
            expiresAt: expiry,
            identity: identity
        )
    }

    // MARK: - Zertifikat laden

    /// Lädt Identity anhand der gespeicherten ID
    func loadIdentity(certificateId: String) -> SecIdentity? {
        guard let persistentRef = Data(base64Encoded: certificateId) else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationLabel as String: persistentRef,
            kSecReturnRef as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            print("⚠️ [KeychainCertificate] Load identity failed: \(status)")
            return nil
        }
        return (result as! SecIdentity)
    }

    // MARK: - Hilfsmethoden

    private func extractEmail(from certificate: SecCertificate) -> String? {
        // Email-Adressen aus Zertifikat extrahieren
        var emails: CFArray?
        let status = SecCertificateCopyEmailAddresses(certificate, &emails)

        guard status == errSecSuccess,
              let emailArray = emails as? [String],
              let firstEmail = emailArray.first else {
            return nil
        }

        return firstEmail
    }

    private func extractExpiry(from certificate: SecCertificate) -> Date? {
        // SecCertificateCopyValues ist nur auf macOS verfügbar
        // Auf iOS ist das Ablaufdatum nicht direkt über Security.framework zugänglich
        // Für vollständige Implementierung wäre ASN.1 DER Parsing erforderlich
        // Das Ablaufdatum ist optional und wird hier nicht extrahiert
        return nil
    }
}

// MARK: - Datenmodelle

struct SigningCertificateInfo: Identifiable, Equatable {
    let id: String
    let displayName: String
    let email: String?
    let expiresAt: Date?
    let identity: SecIdentity

    static func == (lhs: SigningCertificateInfo, rhs: SigningCertificateInfo) -> Bool {
        lhs.id == rhs.id
    }
}
