// MissingTypes.swift
import Foundation

// MIME Entities
public struct MimePartEntity {
    let id: UUID
    let messageId: UUID
    let partNumber: String
    let contentType: String
    let contentSubtype: String?
    let contentId: String?
    let contentDisposition: String?
    let filename: String?
    let size: Int64
    let encoding: String?
    let charset: String?
    let isAttachment: Bool
    let isInline: Bool
    let parentPartNumber: String?
}

public struct BlobMetaEntry {
    let id: UUID
    let sha256: String
    let size: Int64
    let referenceCount: Int
    let createdAt: Date
}

public struct ProcessedMessage {
    let messageId: UUID
    let htmlBody: String?
    let plainTextBody: String?
    let attachments: [AttachmentEntity]
    let mimeParts: [MimePartEntity]
}

public struct ProcessedContent {
    let html: String?
    let plainText: String?
    let attachmentRefs: [String]
}

public struct FinalizedContent {
    let html: String?
    let plainText: String?
    let inlineImages: [String: Data]
}

public struct StorageMetrics {
    let totalBlobs: Int
    let totalSize: Int64
    let deduplicatedCount: Int
}

public class CertificateInfo: NSObject {
    public let subject: String
    public let issuer: String  
    public let validFrom: Date
    public let validTo: Date
    
    public init(subject: String, issuer: String, validFrom: Date, validTo: Date) {
        self.subject = subject
        self.issuer = issuer
        self.validFrom = validFrom
        self.validTo = validTo
        super.init()
    }
}

public enum TrustLevel: Int {
    case untrusted = 0
    case partial = 1
    case trusted = 2
}

public enum ProcessingError: Error {
    case invalidData
    case networkError
    case parsingError
}

// IMAP Types (falls nicht vorhanden)
public struct IMAPBodyPart {
    let partNumber: String
    let type: String
    let subtype: String
    let parameters: [String: String]
    let size: Int64
}
