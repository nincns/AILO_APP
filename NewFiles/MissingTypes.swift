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
    
    public init(partNumber: String, type: MimeContentType, size: Int64? = nil, parameters: [String: String] = [:]) {
        self.partNumber = partNumber
        self.type = type
        self.size = size
        self.parameters = parameters
    }
}
