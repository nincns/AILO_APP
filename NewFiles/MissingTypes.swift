// MissingTypes.swift
import Foundation

// MIME Entities
public struct MimePartEntity {
    public let id: UUID
    public let messageId: UUID
    public let partNumber: String
    public let contentType: String
    public let contentSubtype: String?
    public let contentId: String?
    public let contentDisposition: String?
    public let filename: String?
    public let size: Int64
    public let encoding: String?
    public let charset: String?
    public let isAttachment: Bool
    public let isInline: Bool
    public let parentPartNumber: String?
    
    // FEHLENDE PROPERTIES HINZUGEFÜGT:
    public let partId: String
    public let parentPartId: String?
    public let mediaType: String
    public let transferEncoding: String?
    public let filenameOriginal: String?
    public let filenameNormalized: String?
    public let sizeOctets: Int64
    public let isBodyCandidate: Bool
    public let blobId: String?
    
    // Initializer
    public init(id: UUID, messageId: UUID, partNumber: String, contentType: String,
                contentSubtype: String? = nil, contentId: String? = nil,
                contentDisposition: String? = nil, filename: String? = nil,
                size: Int64, encoding: String? = nil, charset: String? = nil,
                isAttachment: Bool, isInline: Bool, parentPartNumber: String? = nil,
                partId: String, parentPartId: String? = nil, mediaType: String,
                transferEncoding: String? = nil, filenameOriginal: String? = nil,
                filenameNormalized: String? = nil, sizeOctets: Int64,
                isBodyCandidate: Bool, blobId: String? = nil) {
        self.id = id
        self.messageId = messageId
        self.partNumber = partNumber
        self.contentType = contentType
        self.contentSubtype = contentSubtype
        self.contentId = contentId
        self.contentDisposition = contentDisposition
        self.filename = filename
        self.size = size
        self.encoding = encoding
        self.charset = charset
        self.isAttachment = isAttachment
        self.isInline = isInline
        self.parentPartNumber = parentPartNumber
        self.partId = partId
        self.parentPartId = parentPartId
        self.mediaType = mediaType
        self.transferEncoding = transferEncoding
        self.filenameOriginal = filenameOriginal
        self.filenameNormalized = filenameNormalized
        self.sizeOctets = sizeOctets
        self.isBodyCandidate = isBodyCandidate
        self.blobId = blobId
    }
}

public struct BlobMetaEntry {
    let id: UUID
    let sha256: String
    let size: Int64
    let referenceCount: Int
    let createdAt: Date
}

public struct AttachmentEntity {
    public let id: UUID
    public let messageId: UUID
    public let partId: String
    public let filename: String?
    public let mimeType: String
    public let size: Int64
    public let blobId: String?
    public let contentId: String?
    public let isInline: Bool
    
    public init(id: UUID, messageId: UUID, partId: String, filename: String? = nil,
                mimeType: String, size: Int64, blobId: String? = nil,
                contentId: String? = nil, isInline: Bool = false) {
        self.id = id
        self.messageId = messageId
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.blobId = blobId
        self.contentId = contentId
        self.isInline = isInline
    }
}

public struct RenderCacheEntry {
    let messageId: UUID
    let htmlRendered: String?
    let textRendered: String?
    let generatedAt: Date
    let generatorVersion: Int
    
    public init(messageId: UUID, htmlRendered: String?, textRendered: String?, generatedAt: Date, generatorVersion: Int) {
        self.messageId = messageId
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
    }
}

public struct ProcessedMessage {
    public let messageId: UUID
    public let htmlBody: String?
    public let plainTextBody: String?
    public let attachments: [AttachmentEntity]
    public let mimeParts: [MimePartEntity]
    public let hasAttachments: Bool
    public let renderCacheId: String?
    
    public init(messageId: UUID, htmlBody: String? = nil, plainTextBody: String? = nil, 
                attachments: [AttachmentEntity], mimeParts: [MimePartEntity],
                hasAttachments: Bool = false, renderCacheId: String? = nil) {
        self.messageId = messageId
        self.htmlBody = htmlBody
        self.plainTextBody = plainTextBody
        self.attachments = attachments
        self.mimeParts = mimeParts
        self.hasAttachments = hasAttachments
        self.renderCacheId = renderCacheId
    }
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

public struct BlobStorageMetrics {
    public let totalBlobs: Int
    public let totalSize: Int64
    public let deduplicatedCount: Int
    public let averageSize: Int
    
    public init(totalBlobs: Int, totalSize: Int64, deduplicatedCount: Int, averageSize: Int) {
        self.totalBlobs = totalBlobs
        self.totalSize = totalSize
        self.deduplicatedCount = deduplicatedCount
        self.averageSize = averageSize
    }
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
    case timeout
}

public struct StorageError: Error {
    public let isTemporary: Bool
    public let reason: String?
    
    public init(isTemporary: Bool, reason: String? = nil) {
        self.isTemporary = isTemporary
        self.reason = reason
    }
    
    // Convenience static factory methods
    public static let notFound = StorageError(isTemporary: false, reason: "Not found")
    public static let invalidData = StorageError(isTemporary: false, reason: "Invalid data")
    public static let networkError = StorageError(isTemporary: true, reason: "Network error")
    public static let diskFull = StorageError(isTemporary: true, reason: "Disk full")
    public static let corruptedData = StorageError(isTemporary: false, reason: "Corrupted data")
}

public enum AttachmentError: Error {
    case notFound
    case downloadFailed
    case corruptedData
    case alreadyDownloading
    case tooLarge
    case invalidData
}

// IMAP Types (falls nicht vorhanden)
public struct IMAPBodyPart {
    let partNumber: String
    let type: String
    let subtype: String
    let parameters: [String: String]
    let size: Int64
}

public struct IMAPBodyStructure {
    public let rootPart: IMAPBodyPart
    public let parts: [IMAPBodyPart]
    
    public init(rootPart: IMAPBodyPart, parts: [IMAPBodyPart]) {
        self.rootPart = rootPart
        self.parts = parts
    }
}

// MIME Content Types
public enum MimeContentType {
    case text
    case image  
    case audio
    case video
    case application
    case message
    case multipart
    case attachment
    
    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .audio: return "audio"
        case .video: return "video"
        case .application: return "application"
        case .message: return "message"
        case .multipart: return "multipart"
        case .attachment: return "attachment"
        }
    }
}

// Notification Types
public enum NotificationType {
    case message
    case attachment
    case sync
    case error
}

// Circuit Breaker (Placeholder)
public class CircuitBreaker {
    public func reset() {
        // Implementation
    }
    
    public func recordSuccess() {
        // Implementation
    }
    
    public func open(until date: Date) {
        // Implementation
    }
}

// IMAP Client Extensions (Placeholder)
public class IMAPClient {
    public func fetchPartial(messageId: String, partId: String, range: Range<Int>) throws -> Data {
        // Implementation placeholder
        return Data()
    }
    
    public func fetchSection(messageId: String, section: String) throws -> Data {
        // Implementation placeholder
        return Data()
    }
}
