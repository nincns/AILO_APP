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
    
    // New fields for enhanced attachment management
    public var contentId: String?         // for inline attachments (cid:)
    public var isInline: Bool             // true for embedded images
    public var filePath: String?          // path to stored file
    public var checksum: String?          // SHA256 for deduplication
    
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
    }
    
    // Enhanced initializer with metadata
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
    }
}

public enum OutboxStatusEntity: String, Sendable {
    case pending, sending, sent, failed, cancelled
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
    public static let currentVersion: Int = 3

    // Table names
    public static let tAccounts = "accounts"
    public static let tFolders = "folders"
    public static let tMsgHeader = "message_header"
    public static let tMsgBody = "message_body"
    public static let tAttachment = "attachment"
    public static let tOutbox = "outbox"
    public static let tMimeParts = "mime_parts"
    public static let tRenderCache = "render_cache"
    public static let tBlobMeta = "blob_meta"

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

        // Message body (lazy) - V3 schema with raw_body
        """
        CREATE TABLE IF NOT EXISTS \(tMsgBody) (
            account_id TEXT NOT NULL,
            folder TEXT NOT NULL,
            uid TEXT NOT NULL,
            text_body TEXT,
            html_body TEXT,
            has_attachments INTEGER NOT NULL DEFAULT 0,
            raw_body TEXT,
            content_type TEXT,
            charset TEXT,
            transfer_encoding TEXT,
            is_multipart INTEGER NOT NULL DEFAULT 0,
            raw_size INTEGER,
            processed_at INTEGER,
            PRIMARY KEY (account_id, folder, uid)
        );
        """,

        // Attachments
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

    // MARK: - Migration API (storage-agnostic)

    /// Returns the DDL statements to create the schema for a specific version.
    public static func createStatements(for version: Int = currentVersion) -> [String] {
        switch version {
        case 1: return ddl_v1
        case 2: return ddl_v1 // v2 creates full schema with enhanced columns already in ddl_v1
        case 3: return ddl_v1 // v3 creates full schema with raw_body already in ddl_v1
        default: return ddl_v1
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
                // Initial install → create all v3 tables (latest schema)
                steps.append(ddl_v1)
            case 1:
                // v1 → v2: Add enhanced metadata columns
                steps.append(ddl_v2_migrations)
            case 2:
                // v2 → v3: Add raw_body column
                steps.append(ddl_v3_migrations)
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
