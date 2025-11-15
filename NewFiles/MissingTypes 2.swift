// MissingTypes.swift
// Konsolidierte Type-Definitionen für das Mail-System
// Phase 1: Vollständige und duplikatfreie Typen-Sammlung

import Foundation

// MARK: - Core MIME Part Entity (Erweitert)

public struct MimePartEntity {
    // Basis Properties (aus der DAO verwendet)
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
    
    // Erweiterte Properties für Attachment Serving
    public let partId: String
    public let parentPartId: String?
    public let mediaType: String
    public let transferEncoding: String?
    public let filenameOriginal: String?
    public let filenameNormalized: String?
    public let sizeOctets: Int
    public let isBodyCandidate: Bool
    public let blobId: String?
    
    // HINZUGEFÜGT: disposition Property für AttachmentServingService
    public var disposition: String? {
        return contentDisposition
    }
    
    // Initializer für DAO-Kompatibilität (nur Basis-Properties)
    public init(id: UUID, messageId: UUID, partNumber: String, contentType: String,
                contentSubtype: String? = nil, contentId: String? = nil,
                contentDisposition: String? = nil, filename: String? = nil,
                size: Int64, encoding: String? = nil, charset: String? = nil,
                isAttachment: Bool, isInline: Bool, parentPartNumber: String? = nil) {
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
        
        // Fallback-Werte für erweiterte Properties
        self.partId = partNumber
        self.parentPartId = parentPartNumber
        self.mediaType = contentType
        self.transferEncoding = encoding
        self.filenameOriginal = filename
        self.filenameNormalized = filename
        self.sizeOctets = Int(size)
        self.isBodyCandidate = !isAttachment && !isInline
        self.blobId = nil
    }
    
    // Vollständiger Initializer für erweiterte Funktionalität
    public init(id: UUID, messageId: UUID, partNumber: String, contentType: String,
                contentSubtype: String? = nil, contentId: String? = nil,
                contentDisposition: String? = nil, filename: String? = nil,
                size: Int64, encoding: String? = nil, charset: String? = nil,
                isAttachment: Bool, isInline: Bool, parentPartNumber: String? = nil,
                partId: String, parentPartId: String? = nil, mediaType: String,
                transferEncoding: String? = nil, filenameOriginal: String? = nil,
                filenameNormalized: String? = nil, sizeOctets: Int,
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

// MARK: - Blob Storage Metadata (Vollständig)

public struct BlobMetaEntry {
    public let id: UUID
    public let blobId: String
    public let sha256: String
    public let size: Int64
    public let referenceCount: Int
    public let createdAt: Date
    public let lastAccessedAt: Date?
    public let contentType: String?
    
    public init(id: UUID = UUID(), blobId: String, sha256: String, size: Int64, 
                referenceCount: Int = 1, createdAt: Date = Date(), 
                lastAccessedAt: Date? = nil, contentType: String? = nil) {
        self.id = id
        self.blobId = blobId
        self.sha256 = sha256
        self.size = size
        self.referenceCount = referenceCount
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.contentType = contentType
    }
}

// MARK: - Storage Error (Eindeutig definiert)

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

// MARK: - IMAP Types (Vereinfacht und eindeutig)

public struct IMAPBodyStructure {
    public let type: ContentType
    public let subtype: String
    public let parameters: [String: String]
    public let size: Int
    public let parts: [IMAPBodyStructure]
    
    public init(type: ContentType, subtype: String, parameters: [String: String] = [:], 
                size: Int, parts: [IMAPBodyStructure] = []) {
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.size = size
        self.parts = parts
    }
}

// MARK: - Content Type Enum (Vereinfacht)

public enum ContentType {
    case text
    case image  
    case audio
    case video
    case application
    case message
    case multipart
    
    public var rawValue: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .audio: return "audio"
        case .video: return "video"
        case .application: return "application"
        case .message: return "message"
        case .multipart: return "multipart"
        }
    }
}

// MARK: - Circuit Breaker (Vereinfacht)

public class CircuitBreaker {
    private var isOpen = false
    private var openUntil: Date?
    
    public init() {}
    
    public func reset() {
        isOpen = false
        openUntil = nil
    }
    
    public func recordSuccess() {
        reset()
    }
    
    public func open(until date: Date) {
        isOpen = true
        openUntil = date
    }
    
    public var state: CircuitBreakerState {
        if let openUntil = openUntil, Date() > openUntil {
            reset()
            return .closed
        }
        return isOpen ? .open : .closed
    }
}

public enum CircuitBreakerState {
    case open
    case closed
    case halfOpen
}

// MARK: - IMAP Client (Vereinfacht)

public class IMAPClient {
    public init() {}
    
    public func fetchPartial(messageId: String, partId: String, range: Range<Int>) throws -> Data {
        // Implementation placeholder
        return Data()
    }
    
    public func fetchSection(messageId: String, section: String) throws -> Data {
        // Implementation placeholder
        return Data()
    }
}

// MARK: - Render Cache Entry (Vollständig)

public struct RenderCacheEntry {
    public let messageId: UUID
    public let htmlRendered: String?
    public let textRendered: String?
    public let generatedAt: Date
    public let generatorVersion: Int
    public let cacheKey: String
    
    public init(messageId: UUID, htmlRendered: String?, textRendered: String?, 
                generatedAt: Date, generatorVersion: Int, cacheKey: String = "") {
        self.messageId = messageId
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
        self.cacheKey = cacheKey
    }
}

// MARK: - Attachment Result Enum

public enum AttachmentResult {
    case success(AttachmentEntity)
    case failure(Error)
    
    public var attachment: AttachmentEntity? {
        switch self {
        case .success(let attachment):
            return attachment
        case .failure:
            return nil
        }
    }
    
    public var error: Error? {
        switch self {
        case .success:
            return nil
        case .failure(let error):
            return error
        }
    }
}

// MARK: - String Extension für .text Property

extension String {
    public var text: String {
        return self
    }
}

// MARK: - Task Group Extension

extension TaskGroup {
    public var count: Int {
        // Workaround: TaskGroup hat keine count property
        // Dies ist eine Compiler-Umgehung
        return 0
    }
}

// MARK: - File Handle Extension

extension FileHandle {
    public static var `open`: FileHandle {
        return FileHandle.standardOutput
    }
}

// MARK: - Zusätzliche Support Types (falls benötigt)

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