// MissingTypes.swift
import Foundation

// MIME Entities
struct MimePartEntity {
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

struct BlobMetaEntry {
    let id: UUID
    let sha256: String
    let size: Int64
    let referenceCount: Int
    let createdAt: Date
}

struct ProcessedMessage {
    let messageId: UUID
    let htmlBody: String?
    let plainTextBody: String?
    let attachments: [AttachmentEntity]
    let mimeParts: [MimePartEntity]
}

struct ProcessedContent {
    let html: String?
    let plainText: String?
    let attachmentRefs: [String]
}

struct FinalizedContent {
    let html: String?
    let plainText: String?
    let inlineImages: [String: Data]
}

struct StorageMetrics {
    let totalBlobs: Int
    let totalSize: Int64
    let deduplicatedCount: Int
}

struct CertificateInfo {
    let subject: String
    let issuer: String
    let validFrom: Date
    let validTo: Date
}

enum TrustLevel: Int {
    case untrusted = 0
    case partial = 1
    case trusted = 2
}

enum ProcessingError: Error {
    case invalidData
    case networkError
    case parsingError
}

// IMAP Types (falls nicht vorhanden)
struct IMAPBodyPart {
    let partNumber: String
    let type: String
    let subtype: String
    let parameters: [String: String]
    let size: Int64
}
