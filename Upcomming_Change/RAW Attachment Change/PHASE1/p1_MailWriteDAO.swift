// AILO_APP/Database/DAO/MailWriteDAO_V4_Extension.swift
// PHASE 1: Write operations for new V4 tables

import Foundation

// MARK: - MailWriteDAO Extension for V4

extension MailWriteDAO {
    
    // MARK: - MIME Parts
    
    /// Store MIME parts for a message
    /// - Parameters:
    ///   - messageId: UUID of the message
    ///   - parts: Array of MIME parts to store
    public func storeMimeParts(messageId: UUID, parts: [MimePartEntity]) throws {
        try ensureOpen()
        
        let sql = """
            INSERT OR REPLACE INTO \(MailSchema.tMimeParts)
            (id, message_id, part_id, parent_part_id, media_type, charset, transfer_encoding,
             disposition, filename_original, filename_normalized, content_id, content_md5,
             content_sha256, size_octets, bytes_stored, is_body_candidate, blob_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        for part in parts {
            bindUUID(stmt, 1, part.id)
            bindUUID(stmt, 2, messageId)
            bindText(stmt, 3, part.partId)
            bindText(stmt, 4, part.parentPartId)
            bindText(stmt, 5, part.mediaType)
            bindText(stmt, 6, part.charset)
            bindText(stmt, 7, part.transferEncoding)
            bindText(stmt, 8, part.disposition)
            bindText(stmt, 9, part.filenameOriginal)
            bindText(stmt, 10, part.filenameNormalized)
            bindText(stmt, 11, part.contentId)
            bindText(stmt, 12, part.contentMd5)
            bindText(stmt, 13, part.contentSha256)
            bindInt(stmt, 14, part.sizeOctets)
            bindInt(stmt, 15, part.bytesStored)
            bindBool(stmt, 16, part.isBodyCandidate)
            bindText(stmt, 17, part.blobId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "storeMimeParts")
            }
            sqlite3_reset(stmt)
        }
        
        print("✅ [MailWriteDAO] Stored \(parts.count) MIME parts for message \(messageId)")
    }
    
    /// Delete MIME parts for a message
    /// - Parameter messageId: Message UUID
    public func deleteMimeParts(messageId: UUID) throws {
        try ensureOpen()
        
        let sql = "DELETE FROM \(MailSchema.tMimeParts) WHERE message_id = ?"
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "deleteMimeParts")
        }
    }
    
    // MARK: - Render Cache
    
    /// Store or update render cache for a message
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - htmlRendered: Finalized HTML content (with cid: rewritten)
    ///   - textRendered: Finalized plain text content
    ///   - generatorVersion: Parser version for invalidation tracking
    public func storeRenderCache(messageId: UUID, htmlRendered: String?, 
                                  textRendered: String?, generatorVersion: Int = 1) throws {
        try ensureOpen()
        
        let sql = """
            INSERT OR REPLACE INTO \(MailSchema.tRenderCache)
            (message_id, html_rendered, text_rendered, generated_at, generator_version)
            VALUES (?, ?, ?, ?, ?)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        bindText(stmt, 2, htmlRendered)
        bindText(stmt, 3, textRendered)
        bindInt64(stmt, 4, Int64(Date().timeIntervalSince1970))
        bindInt(stmt, 5, generatorVersion)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "storeRenderCache")
        }
        
        print("✅ [MailWriteDAO] Stored render cache for message \(messageId)")
    }
    
    /// Invalidate render cache (e.g. after parser update)
    /// - Parameter generatorVersion: Delete caches older than this version
    public func invalidateRenderCache(olderThan generatorVersion: Int) throws {
        try ensureOpen()
        
        let sql = "DELETE FROM \(MailSchema.tRenderCache) WHERE generator_version < ?"
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindInt(stmt, 1, generatorVersion)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "invalidateRenderCache")
        }
        
        let changes = sqlite3_changes(dbQueue.db)
        print("✅ [MailWriteDAO] Invalidated \(changes) render cache entries")
    }
    
    // MARK: - Blob Store Metadata
    
    /// Register blob in metadata table
    /// - Parameters:
    ///   - blobId: SHA256 hash (from BlobStore)
    ///   - storagePath: Relative path
    ///   - sizeBytes: Size in bytes
    /// - Returns: true if new blob, false if already exists (increments refCount)
    @discardableResult
    public func registerBlob(blobId: String, storagePath: String, sizeBytes: Int) throws -> Bool {
        try ensureOpen()
        
        // Check if exists
        let checkSql = "SELECT ref_count FROM \(MailSchema.tBlobStore) WHERE id = ?"
        let checkStmt = try prepare(checkSql)
        defer { finalize(checkStmt) }
        
        bindText(checkStmt, 1, blobId)
        
        if sqlite3_step(checkStmt) == SQLITE_ROW {
            // Exists - increment ref count
            let currentCount = sqlite3_column_int(checkStmt, 0)
            finalize(checkStmt)
            
            let updateSql = "UPDATE \(MailSchema.tBlobStore) SET ref_count = ? WHERE id = ?"
            let updateStmt = try prepare(updateSql)
            defer { finalize(updateStmt) }
            
            bindInt(updateStmt, 1, Int(currentCount) + 1)
            bindText(updateStmt, 2, blobId)
            
            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw dbError(context: "registerBlob increment")
            }
            
            print("✅ [MailWriteDAO] Incremented ref count for blob \(blobId.prefix(8))... (now \(currentCount + 1))")
            return false
        } else {
            // New blob
            finalize(checkStmt)
            
            let insertSql = """
                INSERT INTO \(MailSchema.tBlobStore)
                (id, storage_path, size_bytes, ref_count, created_at)
                VALUES (?, ?, ?, 1, ?)
            """
            
            let insertStmt = try prepare(insertSql)
            defer { finalize(insertStmt) }
            
            bindText(insertStmt, 1, blobId)
            bindText(insertStmt, 2, storagePath)
            bindInt(insertStmt, 3, sizeBytes)
            bindInt64(insertStmt, 4, Int64(Date().timeIntervalSince1970))
            
            guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                throw dbError(context: "registerBlob insert")
            }
            
            print("✅ [MailWriteDAO] Registered new blob \(blobId.prefix(8))... (\(sizeBytes) bytes)")
            return true
        }
    }
    
    /// Decrement blob reference count
    /// - Parameter blobId: SHA256 hash
    /// - Returns: New ref count (0 means can be deleted)
    @discardableResult
    public func decrementBlobRef(blobId: String) throws -> Int {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tBlobStore)
            SET ref_count = MAX(0, ref_count - 1)
            WHERE id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "decrementBlobRef")
        }
        
        // Get new count
        let checkSql = "SELECT ref_count FROM \(MailSchema.tBlobStore) WHERE id = ?"
        let checkStmt = try prepare(checkSql)
        defer { finalize(checkStmt) }
        
        bindText(checkStmt, 1, blobId)
        
        guard sqlite3_step(checkStmt) == SQLITE_ROW else {
            throw dbError(context: "decrementBlobRef check")
        }
        
        let newCount = Int(sqlite3_column_int(checkStmt, 0))
        print("✅ [MailWriteDAO] Decremented ref count for blob \(blobId.prefix(8))... (now \(newCount))")
        
        return newCount
    }
    
    /// Get blobs with zero references (orphaned)
    /// - Returns: Array of blob IDs that can be deleted
    public func getOrphanedBlobs() throws -> [String] {
        try ensureOpen()
        
        let sql = "SELECT id FROM \(MailSchema.tBlobStore) WHERE ref_count = 0"
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        var orphaned: [String] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = stmt.columnText(0) {
                orphaned.append(id)
            }
        }
        
        return orphaned
    }
    
    /// Delete orphaned blob metadata
    /// - Parameter blobId: Blob to delete
    public func deleteBlobMetadata(blobId: String) throws {
        try ensureOpen()
        
        let sql = "DELETE FROM \(MailSchema.tBlobStore) WHERE id = ? AND ref_count = 0"
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "deleteBlobMetadata")
        }
    }
    
    // MARK: - Migration Support
    
    /// Apply V4 schema (new tables)
    public func migrateToV4() throws {
        try ensureOpen()
        
        print("🔄 [MailWriteDAO] Starting migration to V4...")
        
        // Execute DDL statements
        for ddl in MailSchema.ddl_v4 {
            try execute(ddl)
        }
        
        print("✅ [MailWriteDAO] Migration to V4 complete")
    }
}
