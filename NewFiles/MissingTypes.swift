// MissingTypes.swift
// Konsolidierte Type-Definitionen für das Mail-System
// KEINE DUPLIKATE - nur eine Definition pro Typ

import Foundation

// MARK: - MIME Part Entity

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
    public let partId: String
    public let parentPartId: String?
    public let mediaType: String
    public let transferEncoding: String?
    public let filenameOriginal: String?
    public let filenameNormalized: String?
    public let sizeOctets: Int64
    public let isBodyCandidate: Bool
    public let blobId: String?
    
    public var disposition: String? {
        return contentDisposition
    }
    
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

// MARK: - Blob Storage

public struct BlobMetaEntry {
    public let id: UUID
    public let sha256: String
    public let size: Int64
    public let referenceCount: Int
    public let createdAt: Date
    public let lastAccessedAt: Date?
    
    public init(id: UUID, sha256: String, size: Int64, referenceCount: Int, 
                createdAt: Date, lastAccessedAt: Date? = nil) {
        self.id = id
        self.sha256 = sha256
        self.size = size
        self.referenceCount = referenceCount
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
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

// MARK: - Attachment Entity

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

// MARK: - Render Cache

public struct RenderCacheEntry {
    public let messageId: UUID
    public let htmlRendered: String?
    public let textRendered: String?
    public let generatedAt: Date
    public let generatorVersion: Int
    
    public init(messageId: UUID, htmlRendered: String?, textRendered: String?, 
                generatedAt: Date, generatorVersion: Int) {
        self.messageId = messageId
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
    }
    
    public var isEmpty: Bool {
        return htmlRendered == nil && textRendered == nil
    }
    
    public var sizeBytes: Int {
        return (htmlRendered?.count ?? 0) + (textRendered?.count ?? 0)
    }
}

// MARK: - Processed Message

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
    public let html: String?
    public let plainText: String?
    public let attachmentRefs: [String]
    
    public init(html: String?, plainText: String?, attachmentRefs: [String]) {
        self.html = html
        self.plainText = plainText
        self.attachmentRefs = attachmentRefs
    }
}

public struct FinalizedContent {
    public let html: String?
    public let plainText: String?
    public let inlineImages: [String: Data]
    
    public init(html: String?, plainText: String?, inlineImages: [String: Data]) {
        self.html = html
        self.plainText = plainText
        self.inlineImages = inlineImages
    }
}

// MARK: - Errors

public struct StorageError: Error {
    public let isTemporary: Bool
    public let reason: String?
    
    public init(isTemporary: Bool, reason: String? = nil) {
        self.isTemporary = isTemporary
        self.reason = reason
    }
    
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
    case contentTooLarge
    case invalidEncoding
}

public enum ProcessingError: Error {
    case invalidData
    case networkError
    case parsingError
    case timeout
}

// MARK: - S/MIME & PGP Types

public class CertificateInfo: NSObject {
    public let subject: String
    public let issuer: String
    public let serialNumber: String
    public let validFrom: Date
    public let validUntil: Date
    public let emailAddress: String
    public let trustLevel: TrustLevel
    
    public init(subject: String, issuer: String, serialNumber: String,
                validFrom: Date, validUntil: Date, emailAddress: String,
                trustLevel: TrustLevel) {
        self.subject = subject
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.emailAddress = emailAddress
        self.trustLevel = trustLevel
        super.init()
    }
}

public enum TrustLevel: Int {
    case unknown = 0
    case untrusted = 1
    case marginal = 2
    case trusted = 3
    case invalid = 4
    case revoked = 5
}

// MARK: - IMAP Types

public struct IMAPBodyPart {
    public let partNumber: String
    public let type: String
    public let subtype: String
    public let parameters: [String: String]
    public let size: Int64
    
    public init(partNumber: String, type: String, subtype: String, 
                parameters: [String: String], size: Int64) {
        self.partNumber = partNumber
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.size = size
    }
}

public struct IMAPBodyStructure {
    public let rootPart: IMAPBodyPart
    public let parts: [IMAPBodyPart]
    
    public init(rootPart: IMAPBodyPart, parts: [IMAPBodyPart]) {
        self.rootPart = rootPart
        self.parts = parts
    }
}

// MARK: - MIME Content Types

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

// MARK: - Notification Types

public enum NotificationType {
    case message
    case attachment
    case sync
    case error
}

// MARK: - Circuit Breaker

public class CircuitBreaker {
    private var isOpen = false
    private var failureCount = 0
    private var lastFailureTime: Date?
    
    public func reset() {
        isOpen = false
        failureCount = 0
        lastFailureTime = nil
    }
    
    public func recordSuccess() {
        failureCount = 0
        lastFailureTime = nil
        isOpen = false
    }
    
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        if failureCount >= 3 {
            isOpen = true
        }
    }
    
    public func open(until date: Date) {
        isOpen = true
        lastFailureTime = date
    }
    
    public var canExecute: Bool {
        if !isOpen { return true }
        
        guard let lastFailure = lastFailureTime else { return true }
        let timeout = TimeInterval(60) // 60 seconds
        return Date().timeIntervalSince(lastFailure) > timeout
    }
}

// MARK: - IMAP Client Extensions

public class IMAPClient {
    public func fetchPartial(messageId: String, partId: String, range: Range<Int>) throws -> Data {
        // Implementation placeholder
        return Data()
    }
    
    public func fetchSection(messageId: String, section: String) throws -> Data {
        // Implementation placeholder
        return Data()
    }
    
    public func fetchBodyStructure(messageId: String) throws -> IMAPBodyStructure {
        // Implementation placeholder
        let rootPart = IMAPBodyPart(partNumber: "1", type: "text", subtype: "plain", parameters: [:], size: 0)
        return IMAPBodyStructure(rootPart: rootPart, parts: [])
    }
}

// MARK: - Performance Monitoring

public class PerformanceMonitor {
    public func measure<T>(_ operation: String, block: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let duration = Date().timeIntervalSince(start)
            print("⏱ [\(operation)] took \(String(format: "%.3f", duration))s")
        }
        return try block()
    }
}

// MARK: - Mail Schema

public class MailSchema {
    public static let tMsgHeader = "msg_header"
    public static let tMimeParts = "mime_parts"
    public static let tAttachment = "attachments"
    public static let tRenderCache = "render_cache"
    public static let tBlobMeta = "blob_meta"
    public static let tBlobStore = "blob_store"
    
    public static let ddl_v1: [String] = []
}

// MARK: - DAO Error

public enum DAOError: Error {
    case databaseError(String)
    case sqlError(String)
    case notFound
    case invalidData
}

// MARK: - Message Body Entity

public struct MessageBodyEntity {
    public let messageId: UUID
    public let htmlBody: String?
    public let textBody: String?
    public let hasAttachments: Bool
    
    public init(messageId: UUID, htmlBody: String? = nil, 
                textBody: String? = nil, hasAttachments: Bool = false) {
        self.messageId = messageId
        self.htmlBody = htmlBody
        self.textBody = textBody
        self.hasAttachments = hasAttachments
    }
}

// MARK: - Mail Header

public struct MailHeader {
    public let uid: String
    public let from: String
    public let subject: String
    public let date: Date
    public let flags: [String]
    
    public init(uid: String, from: String, subject: String, 
                date: Date, flags: [String]) {
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}
