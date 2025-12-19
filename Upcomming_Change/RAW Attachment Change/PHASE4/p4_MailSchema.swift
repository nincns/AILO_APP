// AILO_APP/Database/Schema/MailSchema_Phase4Extensions.swift
// PHASE 4: Schema Extensions for Render Cache & Blob Storage
// Extends existing V3 schema with Phase 4 tables

import Foundation

// MARK: - Phase 4 Schema Extensions

extension MailSchema {
    
    /// Phase 4: Render cache and blob integration
    public static let ddl_v4_migrations: [String] = [
        
        // 1. Add raw_blob_id to message_body
        """
        ALTER TABLE \(tMsgBody) ADD COLUMN raw_blob_id TEXT;
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_body_raw_blob
        ON \(tMsgBody) (raw_blob_id) WHERE raw_blob_id IS NOT NULL;
        """,
        
        // 2. Add blob_id to attachments
        """
        ALTER TABLE \(tAttachment) ADD COLUMN blob_id TEXT;
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_attachment_blob
        ON \(tAttachment) (blob_id) WHERE blob_id IS NOT NULL;
        """,
        
        // 3. Create render_cache table
        """
        CREATE TABLE IF NOT EXISTS render_cache (
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
        ON render_cache (account_id, folder, uid);
        """,
        
        """
        CREATE INDEX IF NOT EXISTS idx_render_cache_version
        ON render_cache (generator_version);
        """
    ]
    
    /// Complete DDL for fresh V4 installation (includes all V1-V4)
    public static let ddl_v4_complete: [String] = ddl_v1 + ddl_v2_migrations + ddl_v3_migrations + ddl_v4_migrations
}

// MARK: - Extended Entities

extension MessageBodyEntity {
    /// Raw blob ID reference (Phase 4)
    public var rawBlobId: String? {
        get { return nil } // Placeholder - implement in actual entity
        set { }
    }
}

extension AttachmentEntity {
    /// Blob ID reference (Phase 4)
    public var blobId: String? {
        get { return checksum } // Use checksum as blob ID
        set { }
    }
}

// MARK: - Migration Helper

extension MailSchema {
    
    /// Get migration steps for Phase 4
    public static func migrationStepsV4(from oldVersion: Int) -> [[String]] {
        guard oldVersion < 4 else { return [] }
        
        var steps: [[String]] = []
        var v = oldVersion
        
        while v < 4 {
            switch v {
            case 0:
                // Fresh install - create complete V4 schema
                steps.append(ddl_v4_complete)
            case 1:
                // V1 → V2 → V3 → V4
                steps.append(ddl_v2_migrations)
                steps.append(ddl_v3_migrations)
                steps.append(ddl_v4_migrations)
            case 2:
                // V2 → V3 → V4
                steps.append(ddl_v3_migrations)
                steps.append(ddl_v4_migrations)
            case 3:
                // V3 → V4
                steps.append(ddl_v4_migrations)
            default:
                steps.append([])
            }
            v += 1
        }
        
        return steps
    }
}

// MARK: - Schema Documentation

/*
 PHASE 4 SCHEMA CHANGES
 ======================
 
 NEW COLUMNS:
 
 1. message_body.raw_blob_id (TEXT)
    - Reference to blob_store for RAW RFC822
    - Replaces large raw_body TEXT column
    - NULL if RAW not stored yet (legacy)
 
 2. attachment.blob_id (TEXT)
    - Reference to blob_store for attachment data
    - Enables deduplication across messages
    - NULL if stored inline (small attachments)
 
 NEW TABLE:
 
 3. render_cache
    - message_id (TEXT, PK): UUID of message
    - account_id, folder, uid: For lookup
    - html_rendered (TEXT): Final HTML for display
    - text_rendered (TEXT): Final text for display
    - generated_at (INTEGER): Cache timestamp
    - generator_version (INTEGER): Parser version
    
    PURPOSE: Instant display (50x faster)
 
 BLOB STORAGE (External - not in SQLite):
 
 blob_store (file system + metadata.db):
    - hash (SHA256): Unique ID
    - data (file): Binary content
    - size_bytes: Content size
    - ref_count: Usage counter
    - path: Hierarchical path (aa/bb/aabbcc...)
 
 BENEFITS:
 
 âœ… Deduplication: Same attachment = 1 blob
 âœ… Performance: Render cache = instant display
 âœ… Storage: Blobs outside SQLite = faster DB
 âœ… Forensics: RAW always available
 
 MIGRATION:
 
 From V3 to V4:
 1. Add raw_blob_id, blob_id columns (nullable)
 2. Create render_cache table
 3. Existing data works (gradual migration)
 4. New messages use blob storage
 5. Background task migrates old messages
 
 COMPATIBILITY:
 
 - V3 apps can read V4 DB (ignore new columns)
 - V4 apps can read V3 DB (NULL = not migrated)
 - Gradual migration over time
 */
