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

        // 4. CMS/PKCS#7 Signatur erstellen
        let certData = SecCertificateCopyData(certificate) as Data

        // Bestimme den Algorithmus basierend auf dem Key-Typ
        let algorithm: SecKeyAlgorithm
        if let keyType = SecKeyCopyAttributes(key) as? [String: Any],
           let type = keyType[kSecAttrKeyType as String] as? String {
            if type == (kSecAttrKeyTypeRSA as String) {
                algorithm = .rsaSignatureMessagePKCS1v15SHA256
            } else if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
                algorithm = .ecdsaSignatureMessageX962SHA256
            } else {
                algorithm = .rsaSignatureMessagePKCS1v15SHA256
            }
        } else {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
        }

        // 5. SHA256 Hash des Original-Contents berechnen
        var contentHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        mimeContent.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(mimeContent.count), &contentHash)
        }
        let messageDigest = Data(contentHash)

        // 6. SignedAttributes aufbauen (für Signatur)
        let signedAttrsForSigning = buildSignedAttributesForSigning(messageDigest: messageDigest)

        // 7. Signatur über signedAttributes erstellen (NICHT über Content!)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            algorithm,
            signedAttrsForSigning as CFData,
            &error
        ) as Data? else {
            let errorMsg = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            return .failure(.signingFailed(errorMsg))
        }

        // 8. PKCS#7 SignedData Struktur aufbauen (ASN.1 DER)
        let pkcs7Data = buildPKCS7SignedData(
            messageDigest: messageDigest,
            signature: signature,
            certificate: certData,
            algorithm: algorithm
        )

        // 9. S/MIME multipart/signed Nachricht aufbauen
        let signedData = buildMultipartSigned(
            content: mimeContent,
            pkcs7Signature: pkcs7Data
        )

        return .success(signedData)
    }

    // MARK: - SignedAttributes für Signatur

    /// Baut die signedAttributes für die Signatur-Berechnung
    /// Bei CMS wird über SET OF Attributes signiert (Tag 0x31), nicht über [0] IMPLICIT
    private func buildSignedAttributesForSigning(messageDigest: Data) -> Data {
        let contentTypeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]), // contentType OID
            asn1Set([asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])]) // data OID
        ])

        let signingTimeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]), // signingTime OID
            asn1Set([asn1UTCTime(Date())])
        ])

        let messageDigestAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]), // messageDigest OID
            asn1Set([asn1OctetString(messageDigest)])
        ])

        // Für Signatur: SET OF (Tag 0x31), nicht IMPLICIT [0]
        return asn1Set([contentTypeAttr, signingTimeAttr, messageDigestAttr])
    }

    // MARK: - PKCS#7 SignedData Builder (ASN.1 DER)

    /// Erstellt eine gültige PKCS#7 SignedData Struktur
    private func buildPKCS7SignedData(
        messageDigest: Data,
        signature: Data,
        certificate: Data,
        algorithm: SecKeyAlgorithm
    ) -> Data {
        // OIDs
        let oidSignedData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02] // 1.2.840.113549.1.7.2
        let oidData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01] // 1.2.840.113549.1.7.1
        let oidSHA256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01] // 2.16.840.1.101.3.4.2.1

        // RSA oder ECDSA OID
        let oidSignatureAlgorithm: [UInt8]
        if algorithm == .ecdsaSignatureMessageX962SHA256 {
            // ecdsa-with-SHA256: 1.2.840.10045.4.3.2
            oidSignatureAlgorithm = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        } else {
            // sha256WithRSAEncryption: 1.2.840.113549.1.1.11
            oidSignatureAlgorithm = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        }

        // Issuer und Serial aus Zertifikat extrahieren
        let (issuer, serial) = extractIssuerAndSerial(from: certificate)

        // SignerInfo aufbauen
        let signerInfo = buildSignerInfo(
            issuer: issuer,
            serial: serial,
            digestAlgorithmOID: oidSHA256,
            signatureAlgorithmOID: oidSignatureAlgorithm,
            signature: signature,
            messageDigest: messageDigest
        )

        // DigestAlgorithms SET
        let digestAlgorithms = asn1Set([
            asn1Sequence([asn1OID(oidSHA256), asn1Null()])
        ])

        // EncapContentInfo (detached - kein Content)
        let encapContentInfo = asn1Sequence([
            asn1OID(oidData)
            // Kein Content für detached signature
        ])

        // Certificates [0] IMPLICIT
        let certificates = asn1ContextTag(0, data: certificate, constructed: true)

        // SignerInfos SET
        let signerInfos = asn1Set([signerInfo])

        // SignedData SEQUENCE
        let signedData = asn1Sequence([
            asn1Integer(1), // version
            digestAlgorithms,
            encapContentInfo,
            certificates,
            signerInfos
        ])

        // ContentInfo
        let contentInfo = asn1Sequence([
            asn1OID(oidSignedData),
            asn1ContextTag(0, data: signedData, constructed: true)
        ])

        return contentInfo
    }

    // MARK: - SignerInfo Builder

    private func buildSignerInfo(
        issuer: Data,
        serial: Data,
        digestAlgorithmOID: [UInt8],
        signatureAlgorithmOID: [UInt8],
        signature: Data,
        messageDigest: Data
    ) -> Data {
        // IssuerAndSerialNumber
        let issuerAndSerial = asn1Sequence([issuer, serial])

        // DigestAlgorithm
        let digestAlgorithm = asn1Sequence([asn1OID(digestAlgorithmOID), asn1Null()])

        // SignedAttributes (authenticated attributes)
        let contentTypeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]), // contentType OID
            asn1Set([asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])]) // data OID
        ])

        let signingTimeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]), // signingTime OID
            asn1Set([asn1UTCTime(Date())])
        ])

        let messageDigestAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]), // messageDigest OID
            asn1Set([asn1OctetString(messageDigest)])
        ])

        let signedAttrs = asn1ContextTag(0, data: asn1SequenceContent([
            contentTypeAttr,
            signingTimeAttr,
            messageDigestAttr
        ]), constructed: true)

        // SignatureAlgorithm
        let signatureAlgorithm = asn1Sequence([asn1OID(signatureAlgorithmOID), asn1Null()])

        // Signature
        let signatureValue = asn1OctetString(signature)

        // SignerInfo SEQUENCE
        return asn1Sequence([
            asn1Integer(1), // version
            issuerAndSerial,
            digestAlgorithm,
            signedAttrs,
            signatureAlgorithm,
            signatureValue
        ])
    }

    // MARK: - ASN.1 DER Encoding Helpers

    private func asn1Length(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else if length < 65536 {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        } else {
            return Data([0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        }
    }

    private func asn1Sequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data()) { $0 + $1 }
        return Data([0x30]) + asn1Length(content.count) + content
    }

    private func asn1SequenceContent(_ elements: [Data]) -> Data {
        return elements.reduce(Data()) { $0 + $1 }
    }

    private func asn1Set(_ elements: [Data]) -> Data {
        let content = elements.reduce(Data()) { $0 + $1 }
        return Data([0x31]) + asn1Length(content.count) + content
    }

    private func asn1OID(_ oid: [UInt8]) -> Data {
        return Data([0x06, UInt8(oid.count)]) + Data(oid)
    }

    private func asn1Integer(_ value: Int) -> Data {
        if value < 128 {
            return Data([0x02, 0x01, UInt8(value)])
        } else {
            var bytes: [UInt8] = []
            var v = value
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            if bytes.first! >= 128 {
                bytes.insert(0, at: 0)
            }
            return Data([0x02, UInt8(bytes.count)]) + Data(bytes)
        }
    }

    private func asn1OctetString(_ data: Data) -> Data {
        return Data([0x04]) + asn1Length(data.count) + data
    }

    private func asn1Null() -> Data {
        return Data([0x05, 0x00])
    }

    private func asn1ContextTag(_ tag: UInt8, data: Data, constructed: Bool) -> Data {
        let tagByte: UInt8 = (constructed ? 0xA0 : 0x80) | tag
        return Data([tagByte]) + asn1Length(data.count) + data
    }

    private func asn1UTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timeString = formatter.string(from: date)
        let timeData = timeString.data(using: .ascii)!
        return Data([0x17, UInt8(timeData.count)]) + timeData
    }

    // MARK: - Certificate Parsing

    private func extractIssuerAndSerial(from certData: Data) -> (issuer: Data, serial: Data) {
        // Parse X.509 certificate to extract issuer and serial number
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
        // TBSCertificate ::= SEQUENCE { version, serialNumber, signature, issuer, ... }

        var index = 0
        let bytes = [UInt8](certData)

        // Skip outer SEQUENCE tag
        guard bytes.count > 4, bytes[0] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        index = skipASN1Header(bytes, at: index)

        // Skip TBSCertificate SEQUENCE tag
        guard index < bytes.count, bytes[index] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        index = skipASN1Header(bytes, at: index)

        // Version [0] (optional)
        if index < bytes.count && bytes[index] == 0xA0 {
            index = skipASN1Element(bytes, at: index)
        }

        // Serial Number
        let serialStart = index
        index = skipASN1Element(bytes, at: index)
        let serial = Data(bytes[serialStart..<index])

        // Skip signature algorithm
        index = skipASN1Element(bytes, at: index)

        // Issuer
        let issuerStart = index
        index = skipASN1Element(bytes, at: index)
        let issuer = Data(bytes[issuerStart..<index])

        return (issuer, serial)
    }

    private func skipASN1Header(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1 // Skip tag
        guard i < bytes.count else { return bytes.count }

        if bytes[i] < 128 {
            return i + 1
        } else {
            let numLengthBytes = Int(bytes[i] & 0x7F)
            return i + 1 + numLengthBytes
        }
    }

    private func skipASN1Element(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1 // Skip tag
        guard i < bytes.count else { return bytes.count }

        let length: Int
        if bytes[i] < 128 {
            length = Int(bytes[i])
            i += 1
        } else {
            let numLengthBytes = Int(bytes[i] & 0x7F)
            i += 1
            var len = 0
            for j in 0..<numLengthBytes {
                guard i + j < bytes.count else { return bytes.count }
                len = (len << 8) | Int(bytes[i + j])
            }
            length = len
            i += numLengthBytes
        }

        return min(i + length, bytes.count)
    }

    // MARK: - Multipart Builder

    private func buildMultipartSigned(
        content: Data,
        pkcs7Signature: Data
    ) -> Data {
        let boundary = "----SMIME_BOUNDARY_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"

        var signed = Data()

        // Multipart Header
        let header = "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"\r\n\r\n"
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

        // Base64-kodierte Signatur mit Zeilenumbrüchen (76 Zeichen pro Zeile)
        let base64Signature = pkcs7Signature.base64EncodedString()
        var lineIndex = base64Signature.startIndex
        while lineIndex < base64Signature.endIndex {
            let endIndex = base64Signature.index(lineIndex, offsetBy: 76, limitedBy: base64Signature.endIndex) ?? base64Signature.endIndex
            signed.append(String(base64Signature[lineIndex..<endIndex]).data(using: .utf8)!)
            signed.append("\r\n".data(using: .utf8)!)
            lineIndex = endIndex
        }

        signed.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return signed
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
