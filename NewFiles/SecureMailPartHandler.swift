// AILO_APP/Helpers/Processing/SecureMailPartHandler_Phase7.swift
// PHASE 7: S/MIME and PGP Part Handler
// Detects and handles encrypted/signed email parts

import Foundation
import CryptoKit

// MARK: - Secure Mail Type

public enum SecureMailType: String, Sendable {
    case smimeSigned = "application/pkcs7-signature"
    case smimeSignedAlternative = "application/x-pkcs7-signature"
    case smimeEncrypted = "application/pkcs7-mime"
    case smimeEncryptedAlternative = "application/x-pkcs7-mime"
    case pgpSigned = "application/pgp-signature"
    case pgpEncrypted = "application/pgp-encrypted"
    case pgpKeys = "application/pgp-keys"
    
    public var isEncrypted: Bool {
        switch self {
        case .smimeEncrypted, .smimeEncryptedAlternative, .pgpEncrypted:
            return true
        default:
            return false
        }
    }
    
    public var isSigned: Bool {
        switch self {
        case .smimeSigned, .smimeSignedAlternative, .pgpSigned:
            return true
        default:
            return false
        }
    }
    
    public var protocol: String {
        if rawValue.contains("pkcs7") || rawValue.contains("pkcs7") {
            return "S/MIME"
        } else if rawValue.contains("pgp") {
            return "PGP"
        }
        return "Unknown"
    }
}

// MARK: - Secure Part Info

public struct SecurePartInfo: Sendable {
    public let partId: String
    public let type: SecureMailType
    public let filename: String?
    public let size: Int
    public let blobId: String?
    public let verified: Bool?
    public let signedBy: String?
    public let encryptedFor: [String]?
    
    public init(
        partId: String,
        type: SecureMailType,
        filename: String?,
        size: Int,
        blobId: String?,
        verified: Bool? = nil,
        signedBy: String? = nil,
        encryptedFor: [String]? = nil
    ) {
        self.partId = partId
        self.type = type
        self.filename = filename
        self.size = size
        self.blobId = blobId
        self.verified = verified
        self.signedBy = signedBy
        self.encryptedFor = encryptedFor
    }
}

// MARK: - Secure Mail Detection Result

public struct SecureMailDetectionResult: Sendable {
    public let hasSecureParts: Bool
    public let secureParts: [SecurePartInfo]
    public let isFullyEncrypted: Bool
    public let isFullySigned: Bool
    
    public init(
        hasSecureParts: Bool,
        secureParts: [SecurePartInfo],
        isFullyEncrypted: Bool,
        isFullySigned: Bool
    ) {
        self.hasSecureParts = hasSecureParts
        self.secureParts = secureParts
        self.isFullyEncrypted = isFullyEncrypted
        self.isFullySigned = isFullySigned
    }
}

// MARK: - Secure Mail Part Handler

public class SecureMailPartHandler {
    
    // MARK: - Detection
    
    /// Detect S/MIME and PGP parts in message
    public static func detectSecureParts(in parts: [MIMEPart]) -> SecureMailDetectionResult {
        var secureParts: [SecurePartInfo] = []
        
        for part in parts {
            if let secureType = identifySecureMailType(mediaType: part.mediaType) {
                let info = SecurePartInfo(
                    partId: part.partId,
                    type: secureType,
                    filename: part.filename ?? "\(secureType.protocol) part",
                    size: part.body.utf8.count,
                    blobId: nil // Will be set when stored
                )
                secureParts.append(info)
                
                print("🔐 [SECURE] Detected \(secureType.protocol) part: \(secureType.rawValue)")
            }
        }
        
        let hasEncrypted = secureParts.contains { $0.type.isEncrypted }
        let hasSigned = secureParts.contains { $0.type.isSigned }
        
        // Check if entire message is encrypted (single encrypted part)
        let isFullyEncrypted = secureParts.count == 1 && secureParts[0].type.isEncrypted
        
        // Check if entire message is signed
        let isFullySigned = secureParts.contains { $0.type.isSigned }
        
        return SecureMailDetectionResult(
            hasSecureParts: !secureParts.isEmpty,
            secureParts: secureParts,
            isFullyEncrypted: isFullyEncrypted,
            isFullySigned: isFullySigned
        )
    }
    
    /// Identify secure mail type from media type
    private static func identifySecureMailType(mediaType: String) -> SecureMailType? {
        let normalized = mediaType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // S/MIME types
        if normalized.contains("pkcs7-signature") {
            return .smimeSigned
        }
        if normalized.contains("x-pkcs7-signature") {
            return .smimeSignedAlternative
        }
        if normalized.contains("pkcs7-mime") {
            return .smimeEncrypted
        }
        if normalized.contains("x-pkcs7-mime") {
            return .smimeEncryptedAlternative
        }
        
        // PGP types
        if normalized.contains("pgp-signature") {
            return .pgpSigned
        }
        if normalized.contains("pgp-encrypted") {
            return .pgpEncrypted
        }
        if normalized.contains("pgp-keys") {
            return .pgpKeys
        }
        
        return nil
    }
    
    // MARK: - Part Processing
    
    /// Process secure part and store as attachment
    public static func processSecurePart(
        part: MIMEPart,
        messageId: UUID,
        blobStore: BlobStore
    ) throws -> SecurePartInfo? {
        
        guard let secureType = identifySecureMailType(mediaType: part.mediaType) else {
            return nil
        }
        
        print("🔐 [SECURE] Processing \(secureType.protocol) part \(part.partId)")
        
        // Store the secure part as blob (could be signature file, encrypted payload, etc.)
        let data = Data(part.body.utf8)
        let hash = data.sha256Hash()
        
        try blobStore.store(data: data, hash: hash)
        
        // Generate appropriate filename
        let filename = generateSecurePartFilename(type: secureType, original: part.filename)
        
        return SecurePartInfo(
            partId: part.partId,
            type: secureType,
            filename: filename,
            size: data.count,
            blobId: hash
        )
    }
    
    /// Generate filename for secure part
    private static func generateSecurePartFilename(type: SecureMailType, original: String?) -> String {
        if let original = original {
            return original
        }
        
        switch type {
        case .smimeSigned, .smimeSignedAlternative:
            return "smime.p7s"
        case .smimeEncrypted, .smimeEncryptedAlternative:
            return "smime.p7m"
        case .pgpSigned:
            return "signature.asc"
        case .pgpEncrypted:
            return "encrypted.asc"
        case .pgpKeys:
            return "public_key.asc"
        }
    }
    
    // MARK: - Verification (Stub)
    
    /// Verify S/MIME signature (stub for future implementation)
    public static func verifySMIMESignature(
        signaturePart: MIMEPart,
        signedContent: Data
    ) async -> (verified: Bool, signer: String?) {
        // TODO: Implement S/MIME verification
        // - Parse PKCS7 signature
        // - Verify certificate chain
        // - Check signature validity
        // - Extract signer identity
        
        print("⚠️  [SECURE] S/MIME verification not yet implemented")
        return (false, nil)
    }
    
    /// Decrypt S/MIME encrypted part (stub)
    public static func decryptSMIME(
        encryptedPart: MIMEPart,
        privateKey: Data?
    ) async throws -> Data? {
        // TODO: Implement S/MIME decryption
        // - Parse PKCS7 encrypted data
        // - Find recipient certificate
        // - Decrypt with private key
        // - Return plaintext
        
        print("⚠️  [SECURE] S/MIME decryption not yet implemented")
        throw NSError(
            domain: "SecureMail",
            code: 7200,
            userInfo: [NSLocalizedDescriptionKey: "S/MIME decryption not implemented"]
        )
    }
    
    /// Verify PGP signature (stub)
    public static func verifyPGPSignature(
        signaturePart: MIMEPart,
        signedContent: Data
    ) async -> (verified: Bool, signer: String?) {
        // TODO: Implement PGP verification
        // - Parse PGP signature block
        // - Verify with public key
        // - Check key validity
        
        print("⚠️  [SECURE] PGP verification not yet implemented")
        return (false, nil)
    }
    
    /// Decrypt PGP encrypted part (stub)
    public static func decryptPGP(
        encryptedPart: MIMEPart,
        privateKey: Data?
    ) async throws -> Data? {
        // TODO: Implement PGP decryption
        // - Parse PGP encrypted block
        // - Decrypt with private key
        // - Return plaintext
        
        print("⚠️  [SECURE] PGP decryption not yet implemented")
        throw NSError(
            domain: "SecureMail",
            code: 7201,
            userInfo: [NSLocalizedDescriptionKey: "PGP decryption not implemented"]
        )
    }
    
    // MARK: - UI Helper
    
    /// Generate user-friendly description of secure mail status
    public static func generateSecurityBadge(result: SecureMailDetectionResult) -> String {
        if result.isFullyEncrypted {
            return "🔒 Encrypted"
        }
        
        if result.isFullySigned {
            return "✅ Signed"
        }
        
        if result.hasSecureParts {
            let types = result.secureParts.map { $0.type.protocol }.joined(separator: ", ")
            return "🔐 Contains \(types)"
        }
        
        return ""
    }
    
    /// Get detailed security info for UI
    public static func getSecurityDetails(result: SecureMailDetectionResult) -> [String] {
        var details: [String] = []
        
        for part in result.secureParts {
            if part.type.isEncrypted {
                details.append("Encrypted with \(part.type.protocol)")
            }
            
            if part.type.isSigned {
                if let signer = part.signedBy {
                    details.append("Signed by \(signer)")
                } else {
                    details.append("Digitally signed (verification pending)")
                }
            }
        }
        
        return details
    }
}

// MARK: - Data Extension

extension Data {
    func sha256Hash() -> String {
        let hash = SHA256.hash(data: self)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Usage Documentation

/*
 SECURE MAIL PART HANDLER (Phase 7)
 ===================================
 
 DETECTION:
 ```swift
 let result = SecureMailPartHandler.detectSecureParts(in: mimeParts)
 
 if result.hasSecureParts {
     print("Found \(result.secureParts.count) secure parts")
     
     if result.isFullyEncrypted {
         print("Message is fully encrypted")
     }
     
     if result.isFullySigned {
         print("Message is digitally signed")
     }
 }
 ```
 
 PROCESSING:
 ```swift
 for part in mimeParts {
     if let secureInfo = try SecureMailPartHandler.processSecurePart(
         part: part,
         messageId: messageId,
         blobStore: blobStore
     ) {
         print("Processed: \(secureInfo.type.protocol)")
         print("Stored as: \(secureInfo.filename)")
     }
 }
 ```
 
 UI BADGES:
 ```swift
 let badge = SecureMailPartHandler.generateSecurityBadge(result: result)
 // Returns: "🔒 Encrypted", "✅ Signed", etc.
 
 let details = SecureMailPartHandler.getSecurityDetails(result: result)
 // Returns: ["Encrypted with S/MIME", "Signed by John Doe"]
 ```
 
 VERIFICATION (Future):
 ```swift
 // S/MIME
 let (verified, signer) = await SecureMailPartHandler.verifySMIMESignature(
     signaturePart: signaturePart,
     signedContent: bodyData
 )
 
 // PGP
 let (verified, signer) = await SecureMailPartHandler.verifyPGPSignature(
     signaturePart: signaturePart,
     signedContent: bodyData
 )
 ```
 
 DECRYPTION (Future):
 ```swift
 // S/MIME
 let plaintext = try await SecureMailPartHandler.decryptSMIME(
     encryptedPart: encryptedPart,
     privateKey: myPrivateKey
 )
 
 // PGP
 let plaintext = try await SecureMailPartHandler.decryptPGP(
     encryptedPart: encryptedPart,
     privateKey: myPrivateKey
 )
 ```
 
 SUPPORTED TYPES:
 
 S/MIME:
 - application/pkcs7-signature (signature)
 - application/x-pkcs7-signature (signature alt)
 - application/pkcs7-mime (encrypted/signed data)
 - application/x-pkcs7-mime (encrypted/signed data alt)
 
 PGP:
 - application/pgp-signature (signature)
 - application/pgp-encrypted (encrypted data)
 - application/pgp-keys (public keys)
 
 TYPICAL STRUCTURES:
 
 S/MIME Signed:
 multipart/signed
   text/plain                           <- signed content
   application/pkcs7-signature          <- signature (smime.p7s)
 
 S/MIME Encrypted:
 application/pkcs7-mime                 <- encrypted payload (smime.p7m)
 
 PGP Signed:
 multipart/signed
   text/plain                           <- signed content
   application/pgp-signature            <- signature (signature.asc)
 
 PGP Encrypted:
 multipart/encrypted
   application/pgp-encrypted            <- version info
   application/octet-stream             <- encrypted data
 
 STORAGE:
 - Secure parts stored as attachments in blob store
 - Filename conventions: smime.p7s, smime.p7m, signature.asc, etc.
 - Can be downloaded like regular attachments
 - Verification status stored in attachment metadata
 
 CURRENT STATUS:
 - Detection: ✅ Implemented
 - Storage: ✅ Implemented
 - Verification: ⏳ Stub (future implementation)
 - Decryption: ⏳ Stub (future implementation)
 
 FUTURE INTEGRATION:
 - OpenSSL for S/MIME
 - GnuPG for PGP
 - Certificate store
 - Key management UI
 */
