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

    // MARK: - P12/PFX Import

    /// Importiert ein Zertifikat aus einer P12/PFX-Datei in den App-Schlüsselbund
    func importP12(data: Data, password: String) -> Result<SigningCertificateInfo, P12ImportError> {
        // 1. P12-Datei mit Passwort öffnen
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        var items: CFArray?
        let importStatus = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        guard importStatus == errSecSuccess else {
            print("⚠️ [KeychainCertificate] P12 import failed: \(importStatus)")
            switch importStatus {
            case errSecAuthFailed:
                return .failure(.wrongPassword)
            case errSecDecode:
                return .failure(.invalidFile)
            default:
                return .failure(.importFailed(importStatus))
            }
        }

        guard let itemArray = items as? [[String: Any]],
              let firstItem = itemArray.first else {
            return .failure(.noIdentityFound)
        }

        // 2. Identity extrahieren
        guard let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity? else {
            return .failure(.noIdentityFound)
        }

        // 3. Zertifikat aus Identity extrahieren
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let certificate = certRef else {
            return .failure(.certificateError)
        }

        // 4. Private Key extrahieren für Speicherung
        var privateKeyRef: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKeyRef) == errSecSuccess,
              let privateKey = privateKeyRef else {
            return .failure(.privateKeyError)
        }

        // 5. Zertifikat in Keychain speichern
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var certAddStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        if certAddStatus == errSecDuplicateItem {
            // Bereits vorhanden, das ist OK
            certAddStatus = errSecSuccess
        }

        guard certAddStatus == errSecSuccess else {
            print("⚠️ [KeychainCertificate] Certificate add failed: \(certAddStatus)")
            return .failure(.keychainError(certAddStatus))
        }

        // 6. Private Key in Keychain speichern
        let keyAddQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        var keyAddStatus = SecItemAdd(keyAddQuery as CFDictionary, nil)
        if keyAddStatus == errSecDuplicateItem {
            // Bereits vorhanden, das ist OK
            keyAddStatus = errSecSuccess
        }

        guard keyAddStatus == errSecSuccess else {
            print("⚠️ [KeychainCertificate] Key add failed: \(keyAddStatus)")
            return .failure(.keychainError(keyAddStatus))
        }

        // 7. Infos extrahieren und zurückgeben
        let summary = SecCertificateCopySubjectSummary(certificate) as String? ?? "Importiert"
        let email = extractEmail(from: certificate)

        // ID aus Zertifikat-Hash generieren
        let certData = SecCertificateCopyData(certificate) as Data
        let idString = certData.base64EncodedString().prefix(32).description

        let info = SigningCertificateInfo(
            id: idString,
            displayName: summary,
            email: email,
            expiresAt: nil,
            identity: identity
        )

        print("✅ [KeychainCertificate] P12 imported: \(summary)")
        return .success(info)
    }

    /// Löscht ein Zertifikat aus dem Schlüsselbund
    func deleteCertificate(certificateId: String) -> Bool {
        guard let persistentRef = Data(base64Encoded: certificateId) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationLabel as String: persistentRef
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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

// MARK: - Import Fehler

enum P12ImportError: Error, LocalizedError {
    case wrongPassword
    case invalidFile
    case noIdentityFound
    case certificateError
    case privateKeyError
    case keychainError(OSStatus)
    case importFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            return String(localized: "smime.import.error.password")
        case .invalidFile:
            return String(localized: "smime.import.error.invalid_file")
        case .noIdentityFound:
            return String(localized: "smime.import.error.no_identity")
        case .certificateError:
            return String(localized: "smime.error.certificate")
        case .privateKeyError:
            return String(localized: "smime.error.private_key")
        case .keychainError(let status):
            return String(localized: "smime.import.error.keychain") + " (\(status))"
        case .importFailed(let status):
            return String(localized: "smime.import.error.failed") + " (\(status))"
        }
    }
}
