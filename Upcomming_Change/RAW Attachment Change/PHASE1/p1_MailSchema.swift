// AILO_APP/Core/Storage/MailSchema.swift
// PHASE 1: Schema Extension für MIME-Part Management und Blob Storage
// Version 4: Adds mime_parts, render_cache, blob_store tables

import Foundation

// MARK: - New Entity Models (Phase 1)

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
    public var htmlRendered: String?     // Finalized HTML (cid: rewritten, sanitized)
    public var textRendered: String?     // Finalized plain text
    public var generatedAt: Date         // Timestamp of generation
    public var generatorVersion: Int     // Parser version (for invalidation)
    
    public init(messageId: UUID, htmlRendered: String? = nil, textRendered: String? = nil,
                generatedAt: Date = Date(), generatorVersion: Int = 1) {
        self.messageId = messageId
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

// MARK: - Schema V4 DDL

extension MailSchema {
    /// Schema version 4
    public static let currentVersion_V4: Int = 4
    
    // New table names
    public static let tMimeParts = "mime_parts"
    public static let tRenderCache = "render_cache"
    public static let tBlobStore = "blob_store"
    
    // MARK: DDL v4 - New Tables
    
    public static let ddl_v4: [String] = [
        // MIME Parts - structured MIME tree storage
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
        ON \(tMimeParts) (message_id, content_id);
        """,
        
        // Index for blob reference
        """
        CREATE INDEX IF NOT EXISTS idx_mime_parts_blob
        ON \(tMimeParts) (blob_id);
        """,
        
        // Render Cache - finalized display content
        """
        CREATE TABLE IF NOT EXISTS \(tRenderCache) (
            message_id TEXT PRIMARY KEY,
            html_rendered TEXT,
            text_rendered TEXT,
            generated_at INTEGER NOT NULL,
            generator_version INTEGER NOT NULL DEFAULT 1
        );
        """,
        
        // Blob Store - deduplicated binary storage
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
        """
    ]
    
    // MARK: Migration from V3 to V4
    
    public static let migration_v3_to_v4: [String] = [
        // No schema changes to existing tables
        // New tables are added via ddl_v4
        // Data migration happens in code, not SQL
        """
        -- Migration marker: V3 -> V4
        -- New tables: mime_parts, render_cache, blob_store
        -- Existing data will be migrated by MIMEMigrationService
        """
    ]
}
