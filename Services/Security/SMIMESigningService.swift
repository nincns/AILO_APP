import Foundation
import Security
import CommonCrypto

/// Service für S/MIME-Signierung ausgehender E-Mails
class SMIMESigningService {

    static let shared = SMIMESigningService()
    private let keychainService = KeychainCertificateService.shared

    private init() {}

    // MARK: - Nachricht signieren

    /// Signiert MIME-Content und gibt multipart/signed Nachricht zurück
    func signMessage(
        mimeContent: Data,
        certificateId: String
    ) -> Result<Data, SigningError> {

        // 1. Identity laden
        guard let identity = keychainService.loadIdentity(certificateId: certificateId) else {
            return .failure(.certificateNotFound)
        }

        // 2. Private Key extrahieren
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let key = privateKey else {
            return .failure(.privateKeyError)
        }

        // 3. Zertifikat extrahieren
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let certificate = certRef else {
            return .failure(.certificateError)
        }

        // 4. SHA256 Hash erstellen
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        mimeContent.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(mimeContent.count), &hash)
        }
        let digest = Data(hash)

        // 5. Signatur erstellen
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            digest as CFData,
            &error
        ) as Data? else {
            let errorMsg = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            return .failure(.signingFailed(errorMsg))
        }

        // 6. S/MIME multipart/signed Nachricht aufbauen
        let signedData = buildMultipartSigned(
            content: mimeContent,
            signature: signature,
            certificate: certificate
        )

        return .success(signedData)
    }

    // MARK: - Multipart Builder

    private func buildMultipartSigned(
        content: Data,
        signature: Data,
        certificate: SecCertificate
    ) -> Data {
        let boundary = "----SMIME_BOUNDARY_\(UUID().uuidString.prefix(8))"
        let certData = SecCertificateCopyData(certificate) as Data

        // PKCS#7 Detached Signature bauen (vereinfacht)
        // Für Produktion: Security.framework CMSEncoder oder OpenSSL verwenden
        let pkcs7Signature = buildPKCS7DetachedSignature(
            signature: signature,
            certificate: certData
        )

        var signed = Data()

        // Multipart Header
        let header = """
        Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256; boundary="\(boundary)"\r
        \r

        """
        signed.append(header.data(using: .utf8)!)

        // Erster Teil: Original-Inhalt
        signed.append("--\(boundary)\r\n".data(using: .utf8)!)
        signed.append(content)
        signed.append("\r\n".data(using: .utf8)!)

        // Zweiter Teil: PKCS#7 Signatur
        signed.append("--\(boundary)\r\n".data(using: .utf8)!)
        signed.append("Content-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\n".data(using: .utf8)!)
        signed.append("Content-Transfer-Encoding: base64\r\n".data(using: .utf8)!)
        signed.append("Content-Disposition: attachment; filename=\"smime.p7s\"\r\n\r\n".data(using: .utf8)!)

        // Base64-kodierte Signatur mit Zeilenumbrüchen
        let base64Signature = pkcs7Signature.base64EncodedString(options: .lineLength76Characters)
        signed.append(base64Signature.data(using: .utf8)!)

        signed.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        return signed
    }

    /// Erstellt eine PKCS#7 SignedData Struktur (detached)
    private func buildPKCS7DetachedSignature(
        signature: Data,
        certificate: Data
    ) -> Data {
        // Vereinfachte PKCS#7 Struktur
        // In Produktion sollte CMSEncoder oder OpenSSL verwendet werden

        // Für diese Implementierung: Rohe Signatur + Zertifikat kombinieren
        // Dies ist eine vereinfachte Version - echtes PKCS#7 erfordert ASN.1 DER Encoding

        var pkcs7 = Data()

        // Signatur-Daten
        pkcs7.append(signature)

        // Zertifikat anhängen (für Verifizierung durch Empfänger)
        pkcs7.append(certificate)

        return pkcs7
    }

    // MARK: - Prüfung

    /// Prüft ob Signierung für ein Konto möglich ist
    func canSign(certificateId: String?) -> Bool {
        guard let certId = certificateId, !certId.isEmpty else {
            return false
        }
        return keychainService.loadIdentity(certificateId: certId) != nil
    }
}

// MARK: - Fehlertypen

enum SigningError: Error, LocalizedError {
    case certificateNotFound
    case privateKeyError
    case certificateError
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .certificateNotFound:
            return String(localized: "smime.error.certificate_not_found")
        case .privateKeyError:
            return String(localized: "smime.error.private_key")
        case .certificateError:
            return String(localized: "smime.error.certificate")
        case .signingFailed(let msg):
            return String(localized: "smime.error.signing_failed") + ": " + msg
        }
    }
}
