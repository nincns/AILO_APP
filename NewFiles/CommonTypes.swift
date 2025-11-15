// CommonTypes.swift
// Zentrale Definition aller gemeinsamen Typen für die Attachment-Architektur
// Vermeidet doppelte Deklarationen

import Foundation

// MARK: - Core Entities

public struct MimePartEntity {
    let id: UUID
    let messageId: UUID
    let partId: String
    let parentPartId: String?
    let mediaType: String
    let charset: String?
    let transferEncoding: String?
    let disposition: String?
    let filenameOriginal: String?
    let filenameNormalized: String?
    let contentId: String?
    let contentMd5: String?
    let contentSha256: String?
    let sizeOctets: Int
    let bytesStored: Int?
    let isBodyCandidate: Bool
    let blobId: String?
    let content: Data? = nil  // Optional content field
}

public class RenderCacheEntry: NSObject {
    let messageId: UUID
    let htmlRendered: String?
    let textRendered: String?
    let generatedAt: Date
    let generatorVersion: Int
    let compressed: Bool
    
    init(messageId: UUID,
         htmlRendered: String?,
         textRendered: String?,
         generatedAt: Date,
         generatorVersion: Int,
         compressed: Bool = false) {
        
        self.messageId = messageId
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
        self.compressed = compressed
        super.init()
    }
}

public struct AttachmentInfo {
    let filename: String
    let size: Int
    let isInline: Bool
    let part: MimePartEntity?
    
    init(filename: String, size: Int, isInline: Bool, part: MimePartEntity? = nil) {
        self.filename = filename
        self.size = size
        self.isInline = isInline
        self.part = part
    }
}

public struct BlobMetaEntry {
    let blobId: String
    let hashSha256: String
    let sizeBytes: Int
    let referenceCount: Int
    let createdAt: Date
    let lastAccessed: Date?
}

// MARK: - Message Types

public struct ParsedMessage {
    let mimeParts: [MimePartEntity]
    let bodyParts: [String: Data]
    let attachments: [AttachmentInfo]
    let hasAttachments: Bool
}

public struct ExtractedContent {
    let html: String?
    let text: String?
    let attachments: [AttachmentInfo]
}

// MARK: - IMAP Types

public struct IMAPBodyStructure {
    let rootPart: IMAPBodyPart
}

public struct IMAPBodyPart {
    public enum PartType {
        case text(subtype: String, charset: String?)
        case multipart(subtype: String, parts: [IMAPBodyPart])
        case image(subtype: String, contentId: String?)
        case attachment(mimeType: String, filename: String?)
        case message
    }
    
    let type: PartType
    let size: Int?
    let encoding: String?
    let disposition: String?
    let contentId: String?
    let filename: String?
    
    var mediaType: String {
        switch type {
        case .text(let subtype, _): return "text/\(subtype)"
        case .image(let subtype, _): return "image/\(subtype)"
        case .attachment(let mimeType, _): return mimeType
        case .message: return "message/rfc822"
        case .multipart(let subtype, _): return "multipart/\(subtype)"
        }
    }
    
    var charset: String? {
        if case .text(_, let charset) = type {
            return charset
        }
        return nil
    }
}

// MARK: - Error Types

public enum AttachmentError: Error {
    case alreadyDownloading
    case downloadFailed
    case securityCheckFailed
    case notFound
}

public enum ProcessingError: Error {
    case timeout
    case validationFailed
    case fetchFailed
    case processingFailed(String)
    case contentTooLarge
    case invalidEncoding
}

public enum StorageError: Error {
    case isTemporary(Bool)
    case storageFull
    case writeFailure
}

// MARK: - Security Types

public enum TrustLevel: Int, Comparable {
    case unknown = 0
    case untrusted = 1
    case marginal = 2
    case trusted = 3
    case full = 4
    case verified = 5
    case ultimate = 6
    case certifiedAuthority = 7
    case revoked = -1
    case invalid = -2
    
    public static func < (lhs: TrustLevel, rhs: TrustLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// Certificate must be a class for NSCache
public class CertificateInfo {
    let subject: String
    let issuer: String
    let serialNumber: String
    let validFrom: Date
    let validUntil: Date
    let emailAddress: String
    let trustLevel: TrustLevel
    
    init(subject: String, issuer: String, serialNumber: String,
         validFrom: Date, validUntil: Date, emailAddress: String,
         trustLevel: TrustLevel) {
        self.subject = subject
        self.issuer = issuer
        self.serialNumber = serialNumber
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.emailAddress = emailAddress
        self.trustLevel = trustLevel
    }
}

// MARK: - Blob Store Protocol

public protocol BlobStoreProtocol {
    func store(_ data: Data, messageId: UUID, partId: String) throws -> String
    func retrieve(blobId: String) throws -> Data?
    func exists(blobId: String) -> Bool
    func delete(blobId: String) throws
    func calculateHash(_ data: Data) -> String
    func getStorageMetrics() throws -> StorageMetrics
}

public struct StorageMetrics {
    let totalBlobs: Int
    let totalSize: Int64
    let deduplicatedCount: Int
    let savedSpace: Int64
}

// MARK: - Circuit Breaker

public class CircuitBreaker {
    public enum State {
        case closed
        case open
        case halfOpen
    }
    
    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?
    private let threshold: Int
    private let timeout: TimeInterval
    
    public init(threshold: Int, timeout: TimeInterval) {
        self.threshold = threshold
        self.timeout = timeout
    }
    
    public var currentState: State {
        // Check if should transition from open to half-open
        if state == .open,
           let lastFailure = lastFailureTime,
           Date().timeIntervalSince(lastFailure) > timeout {
            state = .halfOpen
        }
        return state
    }
    
    public func recordSuccess() {
        failureCount = 0
        state = .closed
        lastFailureTime = nil
    }
    
    public func recordFailure() {
        failureCount += 1
        lastFailureTime = Date()
        
        if failureCount >= threshold {
            state = .open
        } else if state == .halfOpen {
            state = .open
        }
    }
    
    public func reset() {
        state = .closed
        failureCount = 0
        lastFailureTime = nil
    }
}
