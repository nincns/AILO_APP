// MissingTypes.swift
// Nur neue Type-Definitionen ohne Duplikate
// Alle bereits existierenden Types wurden entfernt

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
    public let text: String?
    public let plainText: String?
    public let attachmentRefs: [String]

    public init(html: String?, text: String?, plainText: String? = nil, attachmentRefs: [String] = []) {
        self.html = html
        self.text = text
        self.plainText = plainText ?? text
        self.attachmentRefs = attachmentRefs
    }

    // Convenience init without text parameter
    public init(html: String?, text: String?) {
        self.html = html
        self.text = text
        self.plainText = text
        self.attachmentRefs = []
    }
}

public struct FinalizedContent {
    public let html: String?
    public let text: String?
    public let plainText: String?
    public let inlineImages: [String: Data]
    public let generatorVersion: Int

    public init(html: String?, text: String?, plainText: String? = nil, inlineImages: [String: Data] = [:], generatorVersion: Int = 1) {
        self.html = html
        self.text = text
        self.plainText = plainText ?? text
        self.inlineImages = inlineImages
        self.generatorVersion = generatorVersion
    }

    // Convenience init matching MessageProcessingService usage
    public init(html: String?, text: String?, generatorVersion: Int) {
        self.html = html
        self.text = text
        self.plainText = text
        self.inlineImages = [:]
        self.generatorVersion = generatorVersion
    }
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

public enum TrustLevel: Int, Comparable {
    case unknown = 0
    case untrusted = 1
    case marginal = 2
    case trusted = 3
    case invalid = 4
    case revoked = 5

    public static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - MIME Content Types

public enum MimeContentType {
    case text(String, String?) // subtype, charset
    case image(String, String?) // subtype, contentId
    case audio(String)
    case video(String)
    case application(String)
    case message(String)
    case multipart(String, [IMAPBodyPart]) // subtype, parts
    case attachment(String, String?) // mimeType, filename
    
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

// MARK: - IMAP Body Part for Compatibility

public struct IMAPBodyPart {
    public let partNumber: String
    public let type: MimeContentType
    public let size: Int64?
    public let parameters: [String: String]

    // Additional properties for compatibility
    public var mediaType: String {
        switch type {
        case .text(let subtype, _):
            return "text/\(subtype)"
        case .image(let subtype, _):
            return "image/\(subtype)"
        case .audio(let subtype):
            return "audio/\(subtype)"
        case .video(let subtype):
            return "video/\(subtype)"
        case .application(let subtype):
            return "application/\(subtype)"
        case .message(let subtype):
            return "message/\(subtype)"
        case .multipart(let subtype, _):
            return "multipart/\(subtype)"
        case .attachment(let mimeType, _):
            return mimeType
        }
    }

    public var charset: String? {
        if case .text(_, let charset) = type {
            return charset
        }
        return parameters["charset"]
    }

    public var encoding: String? {
        return parameters["encoding"] ?? parameters["content-transfer-encoding"]
    }

    public var filename: String? {
        if case .attachment(_, let filename) = type {
            return filename
        }
        return parameters["filename"] ?? parameters["name"]
    }

    public var contentId: String? {
        if case .image(_, let contentId) = type {
            return contentId
        }
        return parameters["content-id"]
    }

    public var disposition: String? {
        return parameters["content-disposition"]
    }

    public init(partNumber: String, type: MimeContentType, size: Int64? = nil, parameters: [String: String] = [:]) {
        self.partNumber = partNumber
        self.type = type
        self.size = size
        self.parameters = parameters
    }
}

// MARK: - Processing Error

public enum ProcessingError: Error {
    case invalidMessage
    case parsingFailed
    case storageFailed
    case securityCheckFailed
    case timeout
    case cancelled
    case contentTooLarge
    case invalidEncoding
    case contentNotAvailable(partId: String)
    case unknownError(Error)

    public var isRecoverable: Bool {
        switch self {
        case .timeout, .storageFailed:
            return true
        case .invalidMessage, .parsingFailed, .securityCheckFailed, .cancelled:
            return false
        case .contentTooLarge, .invalidEncoding, .contentNotAvailable:
            return false
        case .unknownError:
            return false
        }
    }
}

// Alias for backward compatibility
public typealias MessageProcessingError = ProcessingError

// MARK: - BlobStore Protocol

public protocol BlobStoreProtocol {
    func store(_ data: Data, messageId: UUID, partId: String) throws -> String
    func retrieve(blobId: String) throws -> Data?
    func exists(blobId: String) -> Bool
    func delete(blobId: String) throws
    func storeRawMessage(_ data: Data, messageId: UUID) throws -> String
    func retrieveRawMessage(messageId: UUID) throws -> Data?
}

// MARK: - RenderCache DAO Protocol

public protocol RenderCacheDAO {
    func store(messageId: UUID, html: String?, text: String?, generatorVersion: Int) throws
    func get(messageId: UUID) -> RenderCacheEntry?
    func invalidate(messageId: UUID) throws
}

// MARK: - IMAP Body Structure

public struct IMAPBodyStructure {
    public let rootPart: IMAPBodyPart

    public init(rootPart: IMAPBodyPart) {
        self.rootPart = rootPart
    }
}

// MARK: - Attachment Entity (if not defined elsewhere)

public struct AttachmentEntity {
    public let partId: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let data: Data?
    public let contentId: String?
    public let isInline: Bool
    public let checksum: String?

    public init(partId: String, filename: String, mimeType: String, sizeBytes: Int64,
                data: Data?, contentId: String?, isInline: Bool, checksum: String?) {
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
        self.checksum = checksum
    }
}

// MARK: - MimePartEntity Extensions

extension MimePartEntity {
    public var contentSha256: String? {
        return nil // Computed from blobId or content
    }
}
