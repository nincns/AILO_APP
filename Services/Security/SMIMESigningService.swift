import Foundation
import Security
import CommonCrypto

/// Service für S/MIME-Signierung ausgehender E-Mails
/// Verwendet CMSEncoder auf macOS für korrekte CMS-Struktur
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

        // 2. Zertifikat extrahieren
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let certificate = certRef else {
            return .failure(.certificateError)
        }

        #if os(macOS)
        // Auf macOS: CMSEncoder für korrekte CMS-Struktur verwenden
        return signWithCMSEncoder(
            content: mimeContent,
            identity: identity,
            certificate: certificate
        )
        #else
        // Auf iOS: Manuelle CMS-Erstellung (verbessert)
        return signManually(
            content: mimeContent,
            identity: identity,
            certificate: certificate
        )
        #endif
    }

    #if os(macOS)
    // MARK: - macOS: CMSEncoder (korrekte CMS-Struktur)

    private func signWithCMSEncoder(
        content: Data,
        identity: SecIdentity,
        certificate: SecCertificate
    ) -> Result<Data, SigningError> {
        var encoder: CMSEncoder?
        var status = CMSEncoderCreate(&encoder)
        guard status == errSecSuccess, let cmsEncoder = encoder else {
            return .failure(.signingFailed("CMSEncoderCreate failed: \(status)"))
        }

        // Signer hinzufügen
        status = CMSEncoderAddSigners(cmsEncoder, identity)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSigners failed: \(status)"))
        }

        // Zertifikat einbetten
        status = CMSEncoderAddSupportingCerts(cmsEncoder, [certificate] as CFArray)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSupportingCerts failed: \(status)"))
        }

        // Detached Signatur (Content wird separat übertragen)
        status = CMSEncoderSetHasDetachedContent(cmsEncoder, true)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderSetHasDetachedContent failed: \(status)"))
        }

        // Signing Time hinzufügen
        status = CMSEncoderAddSignedAttributes(cmsEncoder, .attrSigningTime)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSignedAttributes failed: \(status)"))
        }

        // Content zum Signieren übergeben
        status = content.withUnsafeBytes { buffer in
            CMSEncoderUpdateContent(cmsEncoder, buffer.baseAddress!, content.count)
        }
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderUpdateContent failed: \(status)"))
        }

        // Signatur erzeugen
        var encodedData: CFData?
        status = CMSEncoderCopyEncodedContent(cmsEncoder, &encodedData)
        guard status == errSecSuccess, let signatureData = encodedData as Data? else {
            return .failure(.signingFailed("CMSEncoderCopyEncodedContent failed: \(status)"))
        }

        // Multipart/signed Nachricht aufbauen
        let signedMessage = buildMultipartSigned(
            content: content,
            pkcs7Signature: signatureData
        )

        return .success(signedMessage)
    }
    #endif

    // MARK: - iOS: Manuelle CMS-Erstellung

    private func signManually(
        content: Data,
        identity: SecIdentity,
        certificate: SecCertificate
    ) -> Result<Data, SigningError> {
        // Private Key extrahieren
        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let key = privateKey else {
            return .failure(.privateKeyError)
        }

        let certData = SecCertificateCopyData(certificate) as Data

        // Algorithmus bestimmen
        let algorithm: SecKeyAlgorithm
        let isECDSA: Bool
        if let keyType = SecKeyCopyAttributes(key) as? [String: Any],
           let type = keyType[kSecAttrKeyType as String] as? String,
           type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            algorithm = .ecdsaSignatureMessageX962SHA256
            isECDSA = true
        } else {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
            isECDSA = false
        }

        // SHA256 Hash des Contents
        var contentHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        content.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(content.count), &contentHash)
        }
        let messageDigest = Data(contentHash)

        // SignedAttributes aufbauen (EINMAL mit fixem Timestamp)
        let signingTime = Date()
        let signedAttrsContent = buildSignedAttributesContent(
            messageDigest: messageDigest,
            signingTime: signingTime
        )

        // Für Signatur: SET OF Tag (0x31)
        let signedAttrsForSigning = Data([0x31]) + asn1Length(signedAttrsContent.count) + signedAttrsContent

        // Signatur erstellen
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

        // Für SignerInfo: [0] IMPLICIT Tag (0xA0)
        let signedAttrsForSignerInfo = Data([0xA0]) + asn1Length(signedAttrsContent.count) + signedAttrsContent

        // PKCS#7 SignedData erstellen
        let pkcs7Data = buildPKCS7SignedData(
            signature: signature,
            signedAttrs: signedAttrsForSignerInfo,
            certificate: certData,
            isECDSA: isECDSA
        )

        // Multipart/signed Nachricht
        let signedMessage = buildMultipartSigned(
            content: content,
            pkcs7Signature: pkcs7Data
        )

        return .success(signedMessage)
    }

    // MARK: - SignedAttributes Builder

    private func buildSignedAttributesContent(messageDigest: Data, signingTime: Date) -> Data {
        // contentType attribute (1.2.840.113549.1.9.3)
        let contentTypeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]),
            asn1Set([asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])])
        ])

        // signingTime attribute (1.2.840.113549.1.9.5)
        let signingTimeAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]),
            asn1Set([asn1UTCTime(signingTime)])
        ])

        // messageDigest attribute (1.2.840.113549.1.9.4)
        let messageDigestAttr = asn1Sequence([
            asn1OID([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]),
            asn1Set([asn1OctetString(messageDigest)])
        ])

        return contentTypeAttr + signingTimeAttr + messageDigestAttr
    }

    // MARK: - PKCS#7 SignedData Builder

    private func buildPKCS7SignedData(
        signature: Data,
        signedAttrs: Data,
        certificate: Data,
        isECDSA: Bool
    ) -> Data {
        let oidSignedData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        let oidData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        let oidSHA256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]

        let oidSignatureAlgorithm: [UInt8]
        if isECDSA {
            oidSignatureAlgorithm = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        } else {
            oidSignatureAlgorithm = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        }

        let (issuer, serial) = extractIssuerAndSerial(from: certificate)

        let signerInfo = buildSignerInfo(
            issuer: issuer,
            serial: serial,
            digestAlgorithmOID: oidSHA256,
            signatureAlgorithmOID: oidSignatureAlgorithm,
            signedAttrs: signedAttrs,
            signature: signature
        )

        let digestAlgorithms = asn1Set([
            asn1Sequence([asn1OID(oidSHA256), asn1Null()])
        ])

        let encapContentInfo = asn1Sequence([asn1OID(oidData)])
        let certificates = asn1ContextTag(0, data: certificate, constructed: true)
        let signerInfos = asn1Set([signerInfo])

        let signedData = asn1Sequence([
            asn1Integer(1),
            digestAlgorithms,
            encapContentInfo,
            certificates,
            signerInfos
        ])

        return asn1Sequence([
            asn1OID(oidSignedData),
            asn1ContextTag(0, data: signedData, constructed: true)
        ])
    }

    private func buildSignerInfo(
        issuer: Data,
        serial: Data,
        digestAlgorithmOID: [UInt8],
        signatureAlgorithmOID: [UInt8],
        signedAttrs: Data,
        signature: Data
    ) -> Data {
        let issuerAndSerial = asn1Sequence([issuer, serial])
        let digestAlgorithm = asn1Sequence([asn1OID(digestAlgorithmOID), asn1Null()])
        let signatureAlgorithm = asn1Sequence([asn1OID(signatureAlgorithmOID), asn1Null()])
        let signatureValue = asn1OctetString(signature)

        return asn1Sequence([
            asn1Integer(1),
            issuerAndSerial,
            digestAlgorithm,
            signedAttrs,
            signatureAlgorithm,
            signatureValue
        ])
    }

    // MARK: - ASN.1 Helpers

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
            if bytes.first! >= 128 { bytes.insert(0, at: 0) }
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
        var index = 0
        let bytes = [UInt8](certData)

        guard bytes.count > 4, bytes[0] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        index = skipASN1Header(bytes, at: index)

        guard index < bytes.count, bytes[index] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        index = skipASN1Header(bytes, at: index)

        if index < bytes.count && bytes[index] == 0xA0 {
            index = skipASN1Element(bytes, at: index)
        }

        let serialStart = index
        index = skipASN1Element(bytes, at: index)
        let serial = Data(bytes[serialStart..<index])

        index = skipASN1Element(bytes, at: index)

        let issuerStart = index
        index = skipASN1Element(bytes, at: index)
        let issuer = Data(bytes[issuerStart..<index])

        return (issuer, serial)
    }

    private func skipASN1Header(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1
        guard i < bytes.count else { return bytes.count }
        if bytes[i] < 128 { return i + 1 }
        return i + 1 + Int(bytes[i] & 0x7F)
    }

    private func skipASN1Element(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1
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

    private func buildMultipartSigned(content: Data, pkcs7Signature: Data) -> Data {
        let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var result = Data()

        // Header
        let header = "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"\r\n\r\n"
        result.append(header.data(using: .utf8)!)

        // Part 1: Original content (EXAKT wie signiert!)
        result.append("--\(boundary)\r\n".data(using: .utf8)!)
        result.append(content)
        result.append("\r\n".data(using: .utf8)!)

        // Part 2: PKCS#7 Signature
        result.append("--\(boundary)\r\n".data(using: .utf8)!)
        result.append("Content-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\n".data(using: .utf8)!)
        result.append("Content-Transfer-Encoding: base64\r\n".data(using: .utf8)!)
        result.append("Content-Disposition: attachment; filename=\"smime.p7s\"\r\n\r\n".data(using: .utf8)!)

        // Base64 mit 76-Zeichen-Zeilen
        let base64 = pkcs7Signature.base64EncodedString()
        var idx = base64.startIndex
        while idx < base64.endIndex {
            let end = base64.index(idx, offsetBy: 76, limitedBy: base64.endIndex) ?? base64.endIndex
            result.append(String(base64[idx..<end]).data(using: .utf8)!)
            result.append("\r\n".data(using: .utf8)!)
            idx = end
        }

        result.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return result
    }

    // MARK: - Check

    func canSign(certificateId: String?) -> Bool {
        guard let certId = certificateId, !certId.isEmpty else { return false }
        return keychainService.loadIdentity(certificateId: certId) != nil
    }
}

// MARK: - Errors

enum SigningError: Error, LocalizedError {
    case certificateNotFound
    case privateKeyError
    case certificateError
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .certificateNotFound: return String(localized: "smime.error.certificate_not_found")
        case .privateKeyError: return String(localized: "smime.error.private_key")
        case .certificateError: return String(localized: "smime.error.certificate")
        case .signingFailed(let msg): return String(localized: "smime.error.signing_failed") + ": " + msg
        }
    }
}
