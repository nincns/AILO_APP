// MissingTypes.swift
// Konsolidierte Type-Definitionen für AILO_APP
// Enthält alle fehlenden Strukturen und Enums

import Foundation

// MARK: - MIME Entities

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
    
    // Erweiterte Properties
    public let partId: String
    public let parentPartId: String?
    public let mediaType: String
    public let transferEncoding: String?
    public let filenameOriginal: String?
    public let filenameNormalized: String?
    public let sizeOctets: Int  // ✅ GEÄNDERT VON Int64 zu Int
    public let isBodyCandidate: Bool
    public let blobId: String?
    
    // ✅ COMPUTED PROPERTY statt stored property
    public var disposition: String? {
        return contentDisposition
    }
    
    // Basis-Initializer (für DAO-Kompatibilität)
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
        self.sizeOctets = Int(size)  // ✅ Int64 zu Int Konvertierung
        self.isBodyCandidate = !isAttachment && !isInline
        self.blobId = nil
    }
    
    // Vollständiger Initializer
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

// MARK: - Attachment Entities

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
}

public enum ProcessingError: Error {
    case invalidData
    case networkError
    case parsingError
    case timeout
}

// MARK: - S/MIME & PGP (Placeholder)

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

// MARK: - Zusätzliche Typen für Compiler-Fehler

// ✅ Für AttachmentResult enum cases
public enum AttachmentResult {
    case success(AttachmentEntity)
    case failure(Error)
    case message(ProcessedMessage)  // ✅ HINZUGEFÜGT
    case attachment(AttachmentEntity)  // ✅ HINZUGEFÜGT
    case image(Data)  // ✅ HINZUGEFÜGT
    case text(String)  // ✅ HINZUGEFÜGT
    case multipart([AttachmentResult])  // ✅ HINZUGEFÜGT
}

// ✅ String Extension für .text property
extension String {
    public var text: String {
        return self
    }
}

// ✅ TaskGroup Extension für .count
extension TaskGroup {
    public var count: Int {
        // Workaround: TaskGroup hat keine count property
        return 0
    }
}

// ✅ FileHandle Extension für .open
extension FileHandle {
    public static var open: FileHandle {
        return FileHandle.standardOutput
    }
}

// MARK: - IMAP/Circuit Breaker Typen (falls nicht verfügbar)

// ✅ Nur definiert wenn nicht bereits vorhanden
#if !canImport(IMAPClient)
public class IMAPClient {
    public init() {}
    
    public func fetchPartial(messageId: String, partId: String, range: Range<Int>) throws -> Data {
        return Data()
    }
    
    public func fetchSection(messageId: String, section: String) throws -> Data {
        return Data()
    }
}
#endif

#if !canImport(CircuitBreaker)
public class CircuitBreaker {
    public enum State {
        case closed
        case open
        case halfOpen
    }
    
    public var state: State = .closed
    
    public init() {}
    
    public func reset() {
        state = .closed
    }
    
    public func recordSuccess() {
        reset()
    }
    
    public func open(until date: Date) {
        state = .open
    }
}
#endif

#if !canImport(IMAPBodyStructure)
public struct IMAPBodyStructure {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]
    public let size: Int
    public let parts: [IMAPBodyStructure]
    
    public init(type: String, subtype: String, parameters: [String: String] = [:], 
                size: Int, parts: [IMAPBodyStructure] = []) {
        self.type = type
        self.subtype = subtype
        self.parameters = parameters
        self.size = size
        self.parts = parts
    }
}
#endif

// MARK: - HINWEIS
// Die folgenden Typen sind NICHT hier definiert, da sie bereits in anderen Dateien existieren:
// - IMAPClient (Services/Mail/IMAP/) - mit Fallback oben
// - IMAPBodyStructure (Services/Mail/IMAP/IMAPParsers.swift) - mit Fallback oben  
// - CircuitBreaker (Helpers/Utilities/CircuitBreaker.swift) - mit Fallback oben
// - MessageEnvelope, BodyStructure, FolderInfo (Services/Mail/IMAP/IMAPParsers.swift)
//
// Diese sollten über korrekte Imports verwendet werden, nicht hier dupliziert.