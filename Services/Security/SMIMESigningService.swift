import Foundation
import Security
import CommonCrypto

#if canImport(SwiftASN1)
import SwiftASN1
#endif

/// Service für S/MIME-Signierung ausgehender E-Mails
class SMIMESigningService {

    static let shared = SMIMESigningService()
    private let keychainService = KeychainCertificateService.shared

    private init() {}

    // MARK: - Public API

    func signMessage(
        mimeContent: Data,
        certificateId: String
    ) -> Result<Data, SigningError> {

        guard let identity = keychainService.loadIdentity(certificateId: certificateId) else {
            return .failure(.certificateNotFound)
        }

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
              let certificate = certRef else {
            return .failure(.certificateError)
        }

        var privateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              let key = privateKey else {
            return .failure(.privateKeyError)
        }

        #if os(macOS)
        return signWithCMSEncoder(content: mimeContent, identity: identity, certificate: certificate)
        #else
        return signWithManualCMS(content: mimeContent, privateKey: key, certificate: certificate)
        #endif
    }

    func canSign(certificateId: String?) -> Bool {
        guard let certId = certificateId, !certId.isEmpty else { return false }
        return keychainService.loadIdentity(certificateId: certId) != nil
    }

    // MARK: - macOS: CMSEncoder

    #if os(macOS)
    private func signWithCMSEncoder(
        content: Data,
        identity: SecIdentity,
        certificate: SecCertificate
    ) -> Result<Data, SigningError> {
        var encoder: CMSEncoder?
        var status = CMSEncoderCreate(&encoder)
        guard status == errSecSuccess, let cmsEncoder = encoder else {
            return .failure(.signingFailed("CMSEncoderCreate: \(status)"))
        }

        status = CMSEncoderAddSigners(cmsEncoder, identity)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSigners: \(status)"))
        }

        status = CMSEncoderAddSupportingCerts(cmsEncoder, [certificate] as CFArray)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSupportingCerts: \(status)"))
        }

        status = CMSEncoderSetHasDetachedContent(cmsEncoder, true)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderSetHasDetachedContent: \(status)"))
        }

        status = CMSEncoderAddSignedAttributes(cmsEncoder, .attrSigningTime)
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderAddSignedAttributes: \(status)"))
        }

        status = content.withUnsafeBytes { buffer in
            CMSEncoderUpdateContent(cmsEncoder, buffer.baseAddress!, content.count)
        }
        guard status == errSecSuccess else {
            return .failure(.signingFailed("CMSEncoderUpdateContent: \(status)"))
        }

        var encodedData: CFData?
        status = CMSEncoderCopyEncodedContent(cmsEncoder, &encodedData)
        guard status == errSecSuccess, let signatureData = encodedData as Data? else {
            return .failure(.signingFailed("CMSEncoderCopyEncodedContent: \(status)"))
        }

        return .success(buildMultipartSigned(content: content, signature: signatureData))
    }
    #endif

    // MARK: - iOS: Manual CMS with proper ASN.1

    private func signWithManualCMS(
        content: Data,
        privateKey: SecKey,
        certificate: SecCertificate
    ) -> Result<Data, SigningError> {
        let certData = SecCertificateCopyData(certificate) as Data

        // Determine algorithm
        let algorithm: SecKeyAlgorithm
        let digestOID: [UInt8]
        let signatureOID: [UInt8]

        if let attrs = SecKeyCopyAttributes(privateKey) as? [String: Any],
           let keyType = attrs[kSecAttrKeyType as String] as? String,
           keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            algorithm = .ecdsaSignatureMessageX962SHA256
            digestOID = OID.sha256
            signatureOID = OID.ecdsaWithSHA256
        } else {
            algorithm = .rsaSignatureMessagePKCS1v15SHA256
            digestOID = OID.sha256
            signatureOID = OID.sha256WithRSA
        }

        // Hash the content
        let messageDigest = sha256(content)

        // Build signed attributes
        let signingTime = Date()
        let signedAttrsContent = buildSignedAttributes(messageDigest: messageDigest, signingTime: signingTime)

        // Sign the attributes (with SET tag 0x31)
        let signedAttrsForSigning = DER.sequence(tag: 0x31, content: signedAttrsContent)

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            signedAttrsForSigning as CFData,
            &error
        ) as Data? else {
            return .failure(.signingFailed(error?.takeRetainedValue().localizedDescription ?? "Unknown"))
        }

        // Build SignerInfo with [0] IMPLICIT tag for signedAttrs
        let signedAttrsForSignerInfo = DER.sequence(tag: 0xA0, content: signedAttrsContent)

        // Extract issuer and serial from certificate
        let (issuer, serial) = extractIssuerAndSerial(from: certData)

        // Build complete CMS structure
        let cms = buildCMSSignedData(
            certificate: certData,
            issuer: issuer,
            serial: serial,
            digestOID: digestOID,
            signatureOID: signatureOID,
            signedAttrs: signedAttrsForSignerInfo,
            signature: signature
        )

        return .success(buildMultipartSigned(content: content, signature: cms))
    }

    // MARK: - SHA256

    private func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    // MARK: - OIDs

    private enum OID {
        static let signedData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        static let data: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        static let sha256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        static let sha256WithRSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        static let ecdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        static let contentType: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]
        static let messageDigest: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        static let signingTime: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05]
    }

    // MARK: - DER Encoding

    private enum DER {
        static func sequence(tag: UInt8 = 0x30, content: Data) -> Data {
            return Data([tag]) + length(content.count) + content
        }

        static func set(_ content: Data) -> Data {
            return Data([0x31]) + length(content.count) + content
        }

        static func oid(_ bytes: [UInt8]) -> Data {
            return Data([0x06, UInt8(bytes.count)]) + Data(bytes)
        }

        static func integer(_ value: Int) -> Data {
            if value < 128 {
                return Data([0x02, 0x01, UInt8(value)])
            }
            var bytes: [UInt8] = []
            var v = value
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            if bytes.first! >= 128 { bytes.insert(0, at: 0) }
            return Data([0x02, UInt8(bytes.count)]) + Data(bytes)
        }

        static func octetString(_ data: Data) -> Data {
            return Data([0x04]) + length(data.count) + data
        }

        static func null() -> Data {
            return Data([0x05, 0x00])
        }

        static func utcTime(_ date: Date) -> Data {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let str = formatter.string(from: date)
            let data = str.data(using: .ascii)!
            return Data([0x17, UInt8(data.count)]) + data
        }

        static func length(_ len: Int) -> Data {
            if len < 128 {
                return Data([UInt8(len)])
            } else if len < 256 {
                return Data([0x81, UInt8(len)])
            } else if len < 65536 {
                return Data([0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
            } else {
                return Data([0x83, UInt8(len >> 16), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
            }
        }

        static func contextTag(_ tag: UInt8, _ data: Data, constructed: Bool = true) -> Data {
            let tagByte: UInt8 = (constructed ? 0xA0 : 0x80) | tag
            return Data([tagByte]) + length(data.count) + data
        }
    }

    // MARK: - Signed Attributes

    private func buildSignedAttributes(messageDigest: Data, signingTime: Date) -> Data {
        // contentType
        let contentTypeAttr = DER.sequence(content:
            DER.oid(OID.contentType) +
            DER.set(DER.oid(OID.data))
        )

        // signingTime
        let signingTimeAttr = DER.sequence(content:
            DER.oid(OID.signingTime) +
            DER.set(DER.utcTime(signingTime))
        )

        // messageDigest
        let messageDigestAttr = DER.sequence(content:
            DER.oid(OID.messageDigest) +
            DER.set(DER.octetString(messageDigest))
        )

        return contentTypeAttr + signingTimeAttr + messageDigestAttr
    }

    // MARK: - CMS SignedData

    private func buildCMSSignedData(
        certificate: Data,
        issuer: Data,
        serial: Data,
        digestOID: [UInt8],
        signatureOID: [UInt8],
        signedAttrs: Data,
        signature: Data
    ) -> Data {
        // DigestAlgorithmIdentifier
        let digestAlgId = DER.sequence(content: DER.oid(digestOID) + DER.null())

        // DigestAlgorithms SET
        let digestAlgorithms = DER.set(digestAlgId)

        // EncapsulatedContentInfo (detached - no content)
        let encapContentInfo = DER.sequence(content: DER.oid(OID.data))

        // Certificates [0] IMPLICIT
        let certificates = DER.contextTag(0, certificate)

        // SignerInfo
        let signerInfo = buildSignerInfo(
            issuer: issuer,
            serial: serial,
            digestOID: digestOID,
            signatureOID: signatureOID,
            signedAttrs: signedAttrs,
            signature: signature
        )

        // SignerInfos SET
        let signerInfos = DER.set(signerInfo)

        // SignedData SEQUENCE
        let signedData = DER.sequence(content:
            DER.integer(1) +        // version
            digestAlgorithms +
            encapContentInfo +
            certificates +
            signerInfos
        )

        // ContentInfo
        return DER.sequence(content:
            DER.oid(OID.signedData) +
            DER.contextTag(0, signedData)
        )
    }

    private func buildSignerInfo(
        issuer: Data,
        serial: Data,
        digestOID: [UInt8],
        signatureOID: [UInt8],
        signedAttrs: Data,
        signature: Data
    ) -> Data {
        // IssuerAndSerialNumber
        let issuerAndSerial = DER.sequence(content: issuer + serial)

        // DigestAlgorithm
        let digestAlg = DER.sequence(content: DER.oid(digestOID) + DER.null())

        // SignatureAlgorithm
        let sigAlg = DER.sequence(content: DER.oid(signatureOID) + DER.null())

        // Signature (OCTET STRING)
        let sigValue = DER.octetString(signature)

        return DER.sequence(content:
            DER.integer(1) +        // version
            issuerAndSerial +
            digestAlg +
            signedAttrs +           // already has [0] tag
            sigAlg +
            sigValue
        )
    }

    // MARK: - Certificate Parsing

    private func extractIssuerAndSerial(from certData: Data) -> (issuer: Data, serial: Data) {
        let bytes = [UInt8](certData)
        var idx = 0

        guard bytes.count > 4, bytes[0] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        idx = skipHeader(bytes, at: idx)

        guard idx < bytes.count, bytes[idx] == 0x30 else {
            return (Data(), Data([0x02, 0x01, 0x01]))
        }
        idx = skipHeader(bytes, at: idx)

        // Version [0] (optional)
        if idx < bytes.count && bytes[idx] == 0xA0 {
            idx = skipElement(bytes, at: idx)
        }

        // Serial Number
        let serialStart = idx
        idx = skipElement(bytes, at: idx)
        let serial = Data(bytes[serialStart..<idx])

        // Skip signature algorithm
        idx = skipElement(bytes, at: idx)

        // Issuer
        let issuerStart = idx
        idx = skipElement(bytes, at: idx)
        let issuer = Data(bytes[issuerStart..<idx])

        return (issuer, serial)
    }

    private func skipHeader(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1
        guard i < bytes.count else { return bytes.count }
        if bytes[i] < 128 { return i + 1 }
        return i + 1 + Int(bytes[i] & 0x7F)
    }

    private func skipElement(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index + 1
        guard i < bytes.count else { return bytes.count }

        let length: Int
        if bytes[i] < 128 {
            length = Int(bytes[i])
            i += 1
        } else {
            let numBytes = Int(bytes[i] & 0x7F)
            i += 1
            var len = 0
            for j in 0..<numBytes {
                guard i + j < bytes.count else { return bytes.count }
                len = (len << 8) | Int(bytes[i + j])
            }
            length = len
            i += numBytes
        }
        return min(i + length, bytes.count)
    }

    // MARK: - Multipart/Signed MIME

    private func buildMultipartSigned(content: Data, signature: Data) -> Data {
        let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var result = Data()

        let header = "Content-Type: multipart/signed; protocol=\"application/pkcs7-signature\"; micalg=sha-256; boundary=\"\(boundary)\"\r\n\r\n"
        result.append(header.data(using: .utf8)!)

        // Part 1: Original content
        result.append("--\(boundary)\r\n".data(using: .utf8)!)
        result.append(content)
        result.append("\r\n".data(using: .utf8)!)

        // Part 2: Signature
        result.append("--\(boundary)\r\n".data(using: .utf8)!)
        result.append("Content-Type: application/pkcs7-signature; name=\"smime.p7s\"\r\n".data(using: .utf8)!)
        result.append("Content-Transfer-Encoding: base64\r\n".data(using: .utf8)!)
        result.append("Content-Disposition: attachment; filename=\"smime.p7s\"\r\n\r\n".data(using: .utf8)!)

        // Base64 with 76-char lines
        let base64 = signature.base64EncodedString()
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
