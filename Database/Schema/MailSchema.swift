// AILO_APP/Core/Storage/MailSchema.swift
// Defines Core Data / SQLite schema for mail persistence.
// Entities: Account, Folder, MessageHeader, MessageBody, Attachment, OutboxItem.
// Used by MailDAO for CRUD and sync operations.
//
// Version 3 Changes:
// - Added rawBody field to MessageBodyEntity for forensics and validation
// - Support for RAW mail display and .eml export
// - Enhanced security features (DKIM validation, phishing detection)
//
// Version 2 Changes:
// - Enhanced MessageBodyEntity with content processing metadata
// - Enhanced AttachmentEntity with inline/checksum support
// - Migration support from v1 to v2 with ALTER TABLE statements
// - Backward-compatible initializers for existing code

import Foundation

// MARK: - Entity Models (lightweight, storage-agnostic)

public struct AccountEntity: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var displayName: String
    public var emailAddress: String
    public var hostIMAP: String
    public var hostSMTP: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct FolderEntity: Sendable, Equatable {
    public let accountId: UUID
    public let name: String          // server-side name (e.g., "INBOX", "Sent Items")
    public var specialUse: String?   // "inbox", "sent", "drafts", "trash", "spam"
    public var delimiter: String?    // e.g., "/"
    public var attributes: [String]  // raw \Noselect \HasNoChildren …
}

public struct MessageHeaderEntity: Sendable, Identifiable, Equatable {
    public var id: String { uid }
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public var from: String
    public var subject: String
    public var date: Date?
    public var flags: [String]
    public var hasAttachments: Bool  // ✅ NEU
    
    public init(accountId: UUID, folder: String, uid: String, from: String, subject: String, date: Date?, flags: [String], hasAttachments: Bool = false) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
        self.hasAttachments = hasAttachments
    }
}

public struct MessageBodyEntity: Sendable, Equatable {
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public var text: String?
    public var html: String?
    public var hasAttachments: Bool
    
    // ✅ V3: RAW mail storage for forensics, validation, and export
    public var rawBody: String?           // Original RFC822 message (headers + body)
    
    // ✅ V4: Raw blob ID reference for external storage
    public var rawBlobId: String?         // Reference to blob_store for RAW RFC822
    
    // V2: Metadata fields for enhanced content processing
    public var contentType: String?       // e.g. "text/html", "text/plain"
    public var charset: String?           // e.g. "utf-8", "iso-8859-1"
    public var transferEncoding: String?  // e.g. "quoted-printable", "base64"
    public var isMultipart: Bool          // true if multipart/alternative
    public var rawSize: Int?              // Original size before decoding
    public var processedAt: Date?         // Timestamp of processing
    
    // Convenience initializer for backward compatibility
    public init(accountId: UUID, folder: String, uid: String, text: String? = nil, html: String? = nil, hasAttachments: Bool = false) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.text = text
        self.html = html
        self.hasAttachments = hasAttachments
        self.rawBody = nil
        self.rawBlobId = nil
        self.contentType = nil
        self.charset = nil
        self.transferEncoding = nil
        self.isMultipart = false
        self.rawSize = nil
        self.processedAt = nil
    }
    
    // Enhanced initializer with metadata (V2)
    public init(accountId: UUID, folder: String, uid: String, text: String? = nil, html: String? = nil,
                hasAttachments: Bool = false, contentType: String? = nil, charset: String? = nil,
                transferEncoding: String? = nil, isMultipart: Bool = false, rawSize: Int? = nil,
                processedAt: Date? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.text = text
        self.html = html
        self.hasAttachments = hasAttachments
        self.rawBody = nil
        self.rawBlobId = nil
        self.contentType = contentType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.isMultipart = isMultipart
        self.rawSize = rawSize
        self.processedAt = processedAt
    }
    
    // ✅ V3: Full initializer with rawBody
    public init(accountId: UUID, folder: String, uid: String, text: String? = nil, html: String? = nil,
                hasAttachments: Bool = false, rawBody: String? = nil, contentType: String? = nil,
                charset: String? = nil, transferEncoding: String? = nil, isMultipart: Bool = false,
                rawSize: Int? = nil, processedAt: Date? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.text = text
        self.html = html
        self.hasAttachments = hasAttachments
        self.rawBody = rawBody
        self.rawBlobId = nil
        self.contentType = contentType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.isMultipart = isMultipart
        self.rawSize = rawSize
        self.processedAt = processedAt
    }
    
    // ✅ V4: Complete initializer with rawBlobId
    public init(accountId: UUID, folder: String, uid: String, text: String? = nil, html: String? = nil,
                hasAttachments: Bool = false, rawBody: String? = nil, rawBlobId: String? = nil,
                contentType: String? = nil, charset: String? = nil, transferEncoding: String? = nil,
                isMultipart: Bool = false, rawSize: Int? = nil, processedAt: Date? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.text = text
        self.html = html
        self.hasAttachments = hasAttachments
        self.rawBody = rawBody
        self.rawBlobId = rawBlobId
        self.contentType = contentType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.isMultipart = isMultipart
        self.rawSize = rawSize
        self.processedAt = processedAt
    }
}

public struct AttachmentEntity: Sendable, Identifiable, Equatable {
    public var id: String { partId }
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public let partId: String             // e.g., "1.2" or content-id
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    public var data: Data?                // optional: lazy/external storage
    
    // V2: Enhanced attachment metadata
    public var contentId: String?         // for inline attachments (cid:)
    public var isInline: Bool             // true for embedded images
    public var filePath: String?          // path to stored file
    public var checksum: String?          // SHA256 for deduplication
    
    // ✅ V4: Blob storage reference
    public var blobId: String?            // Reference to blob_store
    
    // ✅ V6: Security fields
    public var virusScanStatus: VirusScanStatus
    public var scanDate: Date?
    public var scanEngine: String?
    public var threatName: String?
    public var quarantined: Bool
    public var contentTypeVerified: Bool
    public var detectedContentType: String?
    public var exceedsSizeLimit: Bool
    public var sizeLimitBytes: Int?
    
    // Convenience initializer for backward compatibility
    public init(accountId: UUID, folder: String, uid: String, partId: String,
                filename: String, mimeType: String, sizeBytes: Int, data: Data? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.contentId = nil
        self.isInline = false
        self.filePath = nil
        self.checksum = nil
        self.blobId = nil
        self.virusScanStatus = .pending
        self.scanDate = nil
        self.scanEngine = nil
        self.threatName = nil
        self.quarantined = false
        self.contentTypeVerified = false
        self.detectedContentType = nil
        self.exceedsSizeLimit = false
        self.sizeLimitBytes = nil
    }
    
    // Enhanced initializer with metadata (V2)
    public init(accountId: UUID, folder: String, uid: String, partId: String,
                filename: String, mimeType: String, sizeBytes: Int, data: Data? = nil,
                contentId: String? = nil, isInline: Bool = false, filePath: String? = nil,
                checksum: String? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
        self.filePath = filePath
        self.checksum = checksum
        self.blobId = nil
        self.virusScanStatus = .pending
        self.scanDate = nil
        self.scanEngine = nil
        self.threatName = nil
        self.quarantined = false
        self.contentTypeVerified = false
        self.detectedContentType = nil
        self.exceedsSizeLimit = false
        self.sizeLimitBytes = nil
    }
    
    // ✅ V4: Complete initializer with blob storage
    public init(accountId: UUID, folder: String, uid: String, partId: String,
                filename: String, mimeType: String, sizeBytes: Int, data: Data? = nil,
                contentId: String? = nil, isInline: Bool = false, filePath: String? = nil,
                checksum: String? = nil, blobId: String? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
        self.filePath = filePath
        self.checksum = checksum
        self.blobId = blobId
        self.virusScanStatus = .pending
        self.scanDate = nil
        self.scanEngine = nil
        self.threatName = nil
        self.quarantined = false
        self.contentTypeVerified = false
        self.detectedContentType = nil
        self.exceedsSizeLimit = false
        self.sizeLimitBytes = nil
    }
    
    // ✅ V6: Complete initializer with security fields
    public init(accountId: UUID, folder: String, uid: String, partId: String,
                filename: String, mimeType: String, sizeBytes: Int, data: Data? = nil,
                contentId: String? = nil, isInline: Bool = false, filePath: String? = nil,
                checksum: String? = nil, blobId: String? = nil,
                virusScanStatus: VirusScanStatus = .pending, scanDate: Date? = nil,
                scanEngine: String? = nil, threatName: String? = nil, quarantined: Bool = false,
                contentTypeVerified: Bool = false, detectedContentType: String? = nil,
                exceedsSizeLimit: Bool = false, sizeLimitBytes: Int? = nil) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
        self.filePath = filePath
        self.checksum = checksum
        self.blobId = blobId
        self.virusScanStatus = virusScanStatus
        self.scanDate = scanDate
        self.scanEngine = scanEngine
        self.threatName = threatName
        self.quarantined = quarantined
        self.contentTypeVerified = contentTypeVerified
        self.detectedContentType = detectedContentType
        self.exceedsSizeLimit = exceedsSizeLimit
        self.sizeLimitBytes = sizeLimitBytes
    }
}

// MARK: - New Entity Models (Phase 1 - V4)

public struct MimePartEntity: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let messageId: UUID           // FK to message
    public let partId: String            // IMAP section path (e.g. "1.2")
    public var parentPartId: String?     // For nested multipart
    
    // MIME Metadata
    public var mediaType: String         // e.g. "image/png", "text/html"
    public var charset: String?          // e.g. "utf-8"
    public var transferEncoding: String? // e.g. "base64", "quoted-printable"
    
    // Disposition & Filename
    public var disposition: String?      // "inline", "attachment", or nil
    public var filenameOriginal: String? // Original filename from MIME
    public var filenameNormalized: String? // Sanitized filename
    
    // Content References
    public var contentId: String?        // For cid: references
    public var contentMd5: String?       // MD5 from MIME header (if present)
    public var contentSha256: String?    // Calculated SHA256
    
    // Size Information
    public var sizeOctets: Int?          // Server-reported size
    public var bytesStored: Int?         // Actual stored bytes
    
    // Processing Flags
    public var isBodyCandidate: Bool     // true for text/plain, text/html
    public var blobId: String?           // Reference to blob_store (SHA256)
    
    public init(id: UUID = UUID(), messageId: UUID, partId: String, parentPartId: String? = nil,
                mediaType: String, charset: String? = nil, transferEncoding: String? = nil,
                disposition: String? = nil, filenameOriginal: String? = nil, filenameNormalized: String? = nil,
                contentId: String? = nil, contentMd5: String? = nil, contentSha256: String? = nil,
                sizeOctets: Int? = nil, bytesStored: Int? = nil, isBodyCandidate: Bool = false,
                blobId: String? = nil) {
        self.id = id
        self.messageId = messageId
        self.partId = partId
        self.parentPartId = parentPartId
        self.mediaType = mediaType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.disposition = disposition
        self.filenameOriginal = filenameOriginal
        self.filenameNormalized = filenameNormalized
        self.contentId = contentId
        self.contentMd5 = contentMd5
        self.contentSha256 = contentSha256
        self.sizeOctets = sizeOctets
        self.bytesStored = bytesStored
        self.isBodyCandidate = isBodyCandidate
        self.blobId = blobId
    }
}

public struct RenderCacheEntity: Sendable, Equatable {
    public let messageId: UUID           // PK - one cache per message  
    public let accountId: UUID           // For lookup and FK
    public let folder: String            // For lookup and FK
    public let uid: String               // For lookup and FK
    public var htmlRendered: String?     // Finalized HTML (cid: rewritten, sanitized)
    public var textRendered: String?     // Finalized plain text
    public var generatedAt: Date         // Timestamp of generation
    public var generatorVersion: Int     // Parser version (for invalidation)
    
    public init(messageId: UUID, accountId: UUID, folder: String, uid: String,
                htmlRendered: String? = nil, textRendered: String? = nil,
                generatedAt: Date = Date(), generatorVersion: Int = 1) {
        self.messageId = messageId
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
    }
}

public struct BlobStoreEntity: Sendable, Identifiable, Equatable {
    public let id: String                // PK - SHA256 hash
    public var storagePath: String       // Relative path (e.g. "aa/bb/aabbcc...")
    public var sizeBytes: Int            // Actual file size
    public var refCount: Int             // Reference counter for deduplication
    public var createdAt: Date           // First created timestamp
    
    public init(id: String, storagePath: String, sizeBytes: Int, refCount: Int = 1, createdAt: Date = Date()) {
        self.id = id
        self.storagePath = storagePath
        self.sizeBytes = sizeBytes
        self.refCount = refCount
        self.createdAt = createdAt
    }
}

public enum OutboxStatusEntity: String, Sendable {
    case pending, sending, sent, failed, cancelled
}

// MARK: - Security Entities (Phase 6)

/// Status of virus scan for an attachment
public enum VirusScanStatus: String, Codable, Sendable {
    case pending    // Not yet scanned
    case clean      // Scanned, no threats
    case infected   // Threat detected
    case error      // Scan failed
    case skipped    // Too large or scan disabled
    
    public var description: String {
        switch self {
        case .pending: return "Pending scan"
        case .clean: return "Clean"
        case .infected: return "Infected"
        case .error: return "Scan error"
        case .skipped: return "Not scanned"
        }
    }
    
    public var isAllowedToDownload: Bool {
        return self == .clean || self == .skipped
    }
}

/// Security metadata for an attachment
public struct AttachmentSecurityInfo: Codable, Sendable {
    public let attachmentId: UUID
    public let virusScanStatus: VirusScanStatus
    public let scanDate: Date?
    public let scanEngine: String?
    public let threatName: String?
    public let quarantined: Bool
    public let contentTypeVerified: Bool
    public let originalContentType: String
    public let detectedContentType: String?
    
    public init(
        attachmentId: UUID,
        virusScanStatus: VirusScanStatus,
        scanDate: Date? = nil,
        scanEngine: String? = nil,
        threatName: String? = nil,
        quarantined: Bool = false,
        contentTypeVerified: Bool = false,
        originalContentType: String,
        detectedContentType: String? = nil
    ) {
        self.attachmentId = attachmentId
        self.virusScanStatus = virusScanStatus
        self.scanDate = scanDate
        self.scanEngine = scanEngine
        self.threatName = threatName
        self.quarantined = quarantined
        self.contentTypeVerified = contentTypeVerified
        self.originalContentType = originalContentType
        self.detectedContentType = detectedContentType
    }
}

public struct SecurityAuditLogEntity: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let attachmentId: UUID
    public let messageId: UUID
    public let eventType: String
    public let eventDate: Date
    public var scanStatus: VirusScanStatus?
    public var threatName: String?
    public var actionTaken: String?
    public var userAction: String?
    public var details: String?
    
    public init(id: UUID = UUID(), attachmentId: UUID, messageId: UUID, 
                eventType: String, eventDate: Date = Date(), 
                scanStatus: VirusScanStatus? = nil, threatName: String? = nil,
                actionTaken: String? = nil, userAction: String? = nil, details: String? = nil) {
        self.id = id
        self.attachmentId = attachmentId
        self.messageId = messageId
        self.eventType = eventType
        self.eventDate = eventDate
        self.scanStatus = scanStatus
        self.threatName = threatName
        self.actionTaken = actionTaken
        self.userAction = userAction
        self.details = details
    }
}

public struct QuarantinedAttachmentEntity: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let attachmentId: UUID
    public let messageId: UUID
    public let originalFilename: String
    public let quarantineDate: Date
    public var threatName: String?
    public var threatSeverity: String?
    public var originalBlobId: String?
    public var quarantineBlobId: String?
    public var canRestore: Bool
    public var deleted: Bool
    
    public init(id: UUID = UUID(), attachmentId: UUID, messageId: UUID,
                originalFilename: String, quarantineDate: Date = Date(),
                threatName: String? = nil, threatSeverity: String? = nil,
                originalBlobId: String? = nil, quarantineBlobId: String? = nil,
                canRestore: Bool = false, deleted: Bool = false) {
        self.id = id
        self.attachmentId = attachmentId
        self.messageId = messageId
        self.originalFilename = originalFilename
        self.quarantineDate = quarantineDate
        self.threatName = threatName
        self.threatSeverity = threatSeverity
        self.originalBlobId = originalBlobId
        self.quarantineBlobId = quarantineBlobId
        self.canRestore = canRestore
        self.deleted = deleted
    }
}

public struct OutboxItemEntity: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let accountId: UUID
    public let createdAt: Date
    public var lastAttemptAt: Date?
    public var attempts: Int
    public var status: OutboxStatusEntity
    public var lastError: String?

    // Draft fields for convenience (denormalized)
    public var from: String
    public var to: String        // serialized list (comma-separated)
    public var cc: String
    public var bcc: String
    public var subject: String
    public var textBody: String?
    public var htmlBody: String?
}

// MARK: - SQLite DDL (no external deps)

public enum MailSchema {
    /// Increase when schema changes; DAO should store this in SQLite PRAGMA user_version (or similar)
    public static let currentVersion: Int = 6

    // Original table names
    public static let tAccounts = "accounts"
    public static let tFolders = "folders"
    public static let tMsgHeader = "message_header"
    public static let tMsgBody = "message_body"
    public static let tAttachment = "attachment"
    public static let tOutbox = "outbox"
    
    // New table names for V4
    public static let tMimeParts = "mime_parts"
    public static let tRenderCache = "render_cache"
    public static let tBlobStore = "blob_store"
    
    // New table names for V6 Security
    public static let tSecurityAuditLog = "security_audit_log"
    public static let tQuarantinedAttachments = "quarantined_attachments"

    // MARK: DDL v1

    public static let ddl_v1: [String] = [
        // Accounts (optional; many apps store account config elsewhere)
        """
        CREATE TABLE IF NOT EXISTS \(tAccounts) (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            email_address TEXT NOT NULL,
            host_imap TEXT NOT NULL,
            host_smtp TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """,

        // Folders
        """
        CREATE TABLE IF NOT EXISTS \(tFolders) (
            account_id TEXT NOT NULL,
            name TEXT NOT NULL,
            special_use TEXT,
            delimiter TEXT,
            attributes TEXT,                 -- JSON or space-separated flags
            PRIMARY KEY (account_id, name)
        );
        """,

        // Message headers (hot path; strong composite PK)
        """
        CREATE TABLE IF NOT EXISTS \(tMsgHeader) (
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid TEXT NOT NULL,
            from_addr TEXT,
            subject TEXT,
            date INTEGER,                    -- epoch seconds
            flags TEXT,                      -- space-separated or JSON
            has_attachments INTEGER NOT NULL DEFAULT 0,  -- ✅ NEU
            PRIMARY KEY (account_id, folder, uid)
        );
        """,

        // Index for list ordering (date DESC)
        """
        CREATE INDEX IF NOT EXISTS idx_header_date
        ON \(tMsgHeader) (account_id, folder, date DESC);
        """,

        // Message body (lazy) - V4 schema with blob references
        """
        CREATE TABLE IF NOT EXISTS \(tMsgBody) (
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid TEXT NOT NULL,
            text_body TEXT,
            html_body TEXT,
            has_attachments INTEGER NOT NULL DEFAULT 0,
            raw_body TEXT,
            raw_blob_id TEXT,
            content_type TEXT,
            charset TEXT,
            transfer_encoding TEXT,
            is_multipart INTEGER NOT NULL DEFAULT 0,
            raw_size INTEGER,
            processed_at INTEGER,
            PRIMARY KEY (account_id, folder, uid)
        );
        """,

        // Attachments - V6 schema with security fields
        """
        CREATE TABLE IF NOT EXISTS \(tAttachment) (
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid TEXT NOT NULL,
            part_id TEXT NOT NULL,
            filename TEXT,
            mime_type TEXT,
            size_bytes INTEGER,
            data BLOB,
            content_id TEXT,
            is_inline INTEGER NOT NULL DEFAULT 0,
            file_path TEXT,
            checksum TEXT,
            blob_id TEXT,
            virus_scan_status TEXT DEFAULT 'pending',
            scan_date INTEGER,
            scan_engine TEXT,
            threat_name TEXT,
            quarantined INTEGER DEFAULT 0,
            content_type_verified INTEGER DEFAULT 0,
            detected_content_type TEXT,
            exceeds_size_limit INTEGER DEFAULT 0,
            size_limit_bytes INTEGER,
            PRIMARY KEY (account_id, folder, uid, part_id)
        );
        """,

        // Outbox (queued outgoing messages)
        """
        CREATE TABLE IF NOT EXISTS \(tOutbox) (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_attempt_at INTEGER,
            attempts INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL,
            last_error TEXT,
            from_addr TEXT NOT NULL,
            to_addr TEXT NOT NULL,
            cc_addr TEXT,
            bcc_addr TEXT,
            subject TEXT,
            text_body TEXT,
            html_body TEXT
        );
        """,

        // Helpful indices for outbox processing
        """
        CREATE INDEX IF NOT EXISTS idx_outbox_pending
        ON \(tOutbox) (status, created_at);
        """
    ]

    // MARK: DDL v2 - Enhanced metadata support

    public static let ddl_v2_migrations: [String] = [
        // Add new columns to message_body table
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN content_type TEXT;
        """,
        
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN charset TEXT;
        """,
        
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN transfer_encoding TEXT;
        """,
        
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN is_multipart INTEGER NOT NULL DEFAULT 0;
        """,
        
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN raw_size INTEGER;
        """,
        
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN processed_at INTEGER;
        """,
        
        // Add new columns to attachment table
        """
        ALTER TABLE \(tAttachment) ADD COLUMN content_id TEXT;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN is_inline INTEGER NOT NULL DEFAULT 0;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN file_path TEXT;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN checksum TEXT;
        """,
        
        // Create index for attachment deduplication
        """
        CREATE INDEX IF NOT EXISTS idx_attachment_checksum
        ON \(tAttachment) (checksum) WHERE checksum IS NOT NULL;
        """,
        
        // Create index for processed mails (for migration tracking)
        """
        CREATE INDEX IF NOT EXISTS idx_body_processed_at
        ON \(tMsgBody) (processed_at) WHERE processed_at IS NOT NULL;
        """
    ]
    
    // MARK: DDL v3 - RAW mail storage
    
    public static let ddl_v3_migrations: [String] = [
        // Add raw_body column for forensics and validation
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN raw_body TEXT;
        """
    ]
    
    // MARK: DDL v4 - MIME Parts, Render Cache, and Blob Store
    
    public static let ddl_v4_migrations: [String] = [
        // 1. Add raw_blob_id to message_body for external RAW storage
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN raw_blob_id TEXT;
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_body_raw_blob
        ON \(tMsgBody) (raw_blob_id) WHERE raw_blob_id IS NOT NULL;
        """,
        
        // 2. Add blob_id to attachments for deduplication
        """
        ALTER TABLE \(tAttachment) ADD COLUMN blob_id TEXT;
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_attachment_blob
        ON \(tAttachment) (blob_id) WHERE blob_id IS NOT NULL;
        """,
        
        // 3. MIME Parts - structured MIME tree storage
        """
        CREATE TABLE IF NOT EXISTS \(tMimeParts) (
            id TEXT PRIMARY KEY,
            message_id TEXT NOT NULL,
            part_id TEXT NOT NULL,
            parent_part_id TEXT,
            media_type TEXT NOT NULL,
            charset TEXT,
            transfer_encoding TEXT,
            disposition TEXT,
            filename_original TEXT,
            filename_normalized TEXT,
            content_id TEXT,
            content_md5 TEXT,
            content_sha256 TEXT,
            size_octets INTEGER,
            bytes_stored INTEGER,
            is_body_candidate INTEGER NOT NULL DEFAULT 0,
            blob_id TEXT,
            FOREIGN KEY (blob_id) REFERENCES \(tBlobStore)(id)
        );
        """,
        
        // Index for efficient message lookup
        """
        CREATE INDEX IF NOT EXISTS idx_mime_parts_message
        ON \(tMimeParts) (message_id, part_id);
        """,
        
        // Index for content-id lookup (cid: resolution)
        """
        CREATE INDEX IF NOT EXISTS idx_mime_parts_cid
        ON \(tMimeParts) (message_id, content_id) WHERE content_id IS NOT NULL;
        """,
        
        // Index for blob reference
        """
        CREATE INDEX IF NOT EXISTS idx_mime_parts_blob
        ON \(tMimeParts) (blob_id) WHERE blob_id IS NOT NULL;
        """,
        
        // 4. Render Cache - finalized display content
        """
        CREATE TABLE IF NOT EXISTS \(tRenderCache) (
            message_id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid TEXT NOT NULL,
            html_rendered TEXT,
            text_rendered TEXT,
            generated_at INTEGER NOT NULL,
            generator_version INTEGER NOT NULL DEFAULT 1,
            FOREIGN KEY (account_id, folder, uid) 
                REFERENCES \(tMsgHeader)(account_id, folder, uid) ON DELETE CASCADE
        );
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_render_cache_lookup
        ON \(tRenderCache) (account_id, folder, uid);
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_render_cache_version
        ON \(tRenderCache) (generator_version);
        """,
        
        // 5. Blob Store - deduplicated binary storage
        """
        CREATE TABLE IF NOT EXISTS \(tBlobStore) (
            id TEXT PRIMARY KEY,
            storage_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL
        );
        """,
        
        // Index for orphan cleanup
        """
        CREATE INDEX IF NOT EXISTS idx_blob_store_refcount
        ON \(tBlobStore) (ref_count);
        """,
        
        // Index for storage path lookups
        """
        CREATE INDEX IF NOT EXISTS idx_blob_store_path
        ON \(tBlobStore) (storage_path);
        """
    ]
    
    // MARK: DDL v6 - Security Features (Phase 6)
    
    public static let ddl_v6_migrations: [String] = [
        // 1. Add security columns to attachments table
        """
        ALTER TABLE \(tAttachment) ADD COLUMN virus_scan_status TEXT DEFAULT 'pending';
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN scan_date INTEGER;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN scan_engine TEXT;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN threat_name TEXT;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN quarantined INTEGER DEFAULT 0;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN content_type_verified INTEGER DEFAULT 0;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN detected_content_type TEXT;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN exceeds_size_limit INTEGER DEFAULT 0;
        """,
        
        """
        ALTER TABLE \(tAttachment) ADD COLUMN size_limit_bytes INTEGER;
        """,
        
        // 2. Create index for virus scan status
        """
        CREATE INDEX IF NOT EXISTS idx_attachments_virus_scan
        ON \(tAttachment) (virus_scan_status, quarantined);
        """,
        
        // 3. Security Audit Log table
        """
        CREATE TABLE IF NOT EXISTS \(tSecurityAuditLog) (
            id TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            event_date INTEGER NOT NULL,
            scan_status TEXT,
            threat_name TEXT,
            action_taken TEXT,
            user_action TEXT,
            details TEXT
        );
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_security_audit_attachment
        ON \(tSecurityAuditLog) (attachment_id);
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_security_audit_date
        ON \(tSecurityAuditLog) (event_date);
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_security_audit_event
        ON \(tSecurityAuditLog) (event_type);
        """,
        
        // 4. Quarantined Attachments table
        """
        CREATE TABLE IF NOT EXISTS \(tQuarantinedAttachments) (
            id TEXT PRIMARY KEY,
            attachment_id TEXT NOT NULL UNIQUE,
            message_id TEXT NOT NULL,
            original_filename TEXT NOT NULL,
            quarantine_date INTEGER NOT NULL,
            threat_name TEXT,
            threat_severity TEXT,
            original_blob_id TEXT,
            quarantine_blob_id TEXT,
            can_restore INTEGER DEFAULT 0,
            deleted INTEGER DEFAULT 0
        );
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_quarantine_date
        ON \(tQuarantinedAttachments) (quarantine_date);
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_quarantine_attachment
        ON \(tQuarantinedAttachments) (attachment_id);
        """
    ]

    // MARK: - Migration API (storage-agnostic)

    /// Returns the DDL statements to create the schema for a specific version.
    public static func createStatements(for version: Int = currentVersion) -> [String] {
        switch version {
        case 1: return ddl_v1
        case 2: return ddl_v1 // v2 creates full schema with enhanced columns already in ddl_v1
        case 3: return ddl_v1 // v3 creates full schema with raw_body already in ddl_v1
        case 4: return ddl_v1 + ddl_v4_migrations // v4 creates v1 schema plus new tables
        case 5: return ddl_v1 + ddl_v4_migrations // v5 is same as v4
        case 6: return ddl_v1 + ddl_v4_migrations + ddl_v6_migrations // v6 adds security
        default: return ddl_v1 + ddl_v4_migrations + ddl_v6_migrations
        }
    }

    /// Compute stepwise migrations from an older user_version to currentVersion.
    /// DAO is responsible for executing returned SQL in a transaction and writing PRAGMA user_version.
    public static func migrationSteps(from oldVersion: Int, to newVersion: Int = currentVersion) -> [[String]] {
        guard oldVersion < newVersion else { return [] }
        var steps: [[String]] = []
        var v = oldVersion
        while v < newVersion {
            switch v {
            case 0:
                // Initial install → create all v4 tables (latest schema)
                steps.append(ddl_v1)
            case 1:
                // v1 → v2: Add enhanced metadata columns
                steps.append(ddl_v2_migrations)
            case 2:
                // v2 → v3: Add raw_body column
                steps.append(ddl_v3_migrations)
            case 3:
                // v3 → v4: Add blob storage and render cache
                steps.append(ddl_v4_migrations)
            case 4:
                // v4 → v5: No changes (placeholder version)
                steps.append([])
            case 5:
                // v5 → v6: Add security features
                steps.append(ddl_v6_migrations)
            default:
                steps.append([])
            }
            v += 1
        }
        return steps
    }

    // MARK: - Helper to bind with SQLite PRAGMA user_version

    /// A tiny helper the DAO can use for schema setup.
    /// - Parameters:
    ///   - readUserVersion: closure returning current PRAGMA user_version (0 if empty DB)
    ///   - exec: closure to execute an SQL statement (should throw on error)
    ///   - writeUserVersion: closure to set PRAGMA user_version after each successful step
    public static func migrateIfNeeded(
        readUserVersion: () throws -> Int,
        exec: (String) throws -> Void,
        writeUserVersion: (Int) throws -> Void
    ) throws {
        let current = try readUserVersion()
        if current == 0 {
            // fresh DB → create schema at currentVersion
            for stmt in createStatements(for: currentVersion) {
                try exec(stmt)
            }
            try writeUserVersion(currentVersion)
            return
        }

        if current < currentVersion {
            let steps = migrationSteps(from: current, to: currentVersion)
            var v = current
            for step in steps {
                for stmt in step { try exec(stmt) }
                v += 1
                try writeUserVersion(v)
            }
        }
    }
}

// MARK: - Type Aliases

/// Legacy type alias for backward compatibility
public typealias Header = MessageHeaderEntity
