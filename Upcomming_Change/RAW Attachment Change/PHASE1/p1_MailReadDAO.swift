// AILO_APP/Database/DAO/MailReadDAO_V4_Extension.swift
// PHASE 1: Read operations for new V4 tables

import Foundation

// MARK: - MailReadDAO Extension for V4

extension MailReadDAO {
    
    // MARK: - MIME Parts
    
    /// Get all MIME parts for a message
    /// - Parameter messageId: Message UUID
    /// - Returns: Array of MIME parts, sorted by part_id
    public func getMimeParts(messageId: UUID) throws -> [MimePartEntity] {
        try ensureOpen()
        
        let sql = """
            SELECT id, message_id, part_id, parent_part_id, media_type, charset, transfer_encoding,
                   disposition, filename_original, filename_normalized, content_id, content_md5,
                   content_sha256, size_octets, bytes_stored, is_body_candidate, blob_id
            FROM \(MailSchema.tMimeParts)
            WHERE message_id = ?
            ORDER BY part_id
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        
        var parts: [MimePartEntity] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let part = MimePartEntity(
                id: stmt.columnUUID(0),
                messageId: stmt.columnUUID(1),
                partId: stmt.columnText(2) ?? "",
                parentPartId: stmt.columnText(3),
                mediaType: stmt.columnText(4) ?? "",
                charset: stmt.columnText(5),
                transferEncoding: stmt.columnText(6),
                disposition: stmt.columnText(7),
                filenameOriginal: stmt.columnText(8),
                filenameNormalized: stmt.columnText(9),
                contentId: stmt.columnText(10),
                contentMd5: stmt.columnText(11),
                contentSha256: stmt.columnText(12),
                sizeOctets: stmt.columnInt(13),
                bytesStored: stmt.columnInt(14),
                isBodyCandidate: stmt.columnBool(15),
                blobId: stmt.columnText(16)
            )
            parts.append(part)
        }
        
        return parts
    }
    
    /// Get a specific MIME part by content-id (for cid: resolution)
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - contentId: Content-ID value (without "cid:" prefix)
    /// - Returns: MIME part entity if found
    public func getMimePartByContentId(messageId: UUID, contentId: String) throws -> MimePartEntity? {
        try ensureOpen()
        
        let sql = """
            SELECT id, message_id, part_id, parent_part_id, media_type, charset, transfer_encoding,
                   disposition, filename_original, filename_normalized, content_id, content_md5,
                   content_sha256, size_octets, bytes_stored, is_body_candidate, blob_id
            FROM \(MailSchema.tMimeParts)
            WHERE message_id = ? AND content_id = ?
            LIMIT 1
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        bindText(stmt, 2, contentId)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return MimePartEntity(
            id: stmt.columnUUID(0),
            messageId: stmt.columnUUID(1),
            partId: stmt.columnText(2) ?? "",
            parentPartId: stmt.columnText(3),
            mediaType: stmt.columnText(4) ?? "",
            charset: stmt.columnText(5),
            transferEncoding: stmt.columnText(6),
            disposition: stmt.columnText(7),
            filenameOriginal: stmt.columnText(8),
            filenameNormalized: stmt.columnText(9),
            contentId: stmt.columnText(10),
            contentMd5: stmt.columnText(11),
            contentSha256: stmt.columnText(12),
            sizeOctets: stmt.columnInt(13),
            bytesStored: stmt.columnInt(14),
            isBodyCandidate: stmt.columnBool(15),
            blobId: stmt.columnText(16)
        )
    }
    
    /// Get body candidate MIME parts (text/plain, text/html)
    /// - Parameter messageId: Message UUID
    /// - Returns: Array of body parts, sorted by preference (HTML first)
    public func getBodyCandidateParts(messageId: UUID) throws -> [MimePartEntity] {
        try ensureOpen()
        
        let sql = """
            SELECT id, message_id, part_id, parent_part_id, media_type, charset, transfer_encoding,
                   disposition, filename_original, filename_normalized, content_id, content_md5,
                   content_sha256, size_octets, bytes_stored, is_body_candidate, blob_id
            FROM \(MailSchema.tMimeParts)
            WHERE message_id = ? AND is_body_candidate = 1
            ORDER BY CASE media_type 
                WHEN 'text/html' THEN 1 
                WHEN 'text/plain' THEN 2 
                ELSE 3 
            END
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        
        var parts: [MimePartEntity] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let part = MimePartEntity(
                id: stmt.columnUUID(0),
                messageId: stmt.columnUUID(1),
                partId: stmt.columnText(2) ?? "",
                parentPartId: stmt.columnText(3),
                mediaType: stmt.columnText(4) ?? "",
                charset: stmt.columnText(5),
                transferEncoding: stmt.columnText(6),
                disposition: stmt.columnText(7),
                filenameOriginal: stmt.columnText(8),
                filenameNormalized: stmt.columnText(9),
                contentId: stmt.columnText(10),
                contentMd5: stmt.columnText(11),
                contentSha256: stmt.columnText(12),
                sizeOctets: stmt.columnInt(13),
                bytesStored: stmt.columnInt(14),
                isBodyCandidate: stmt.columnBool(15),
                blobId: stmt.columnText(16)
            )
            parts.append(part)
        }
        
        return parts
    }
    
    // MARK: - Render Cache
    
    /// Get render cache for a message
    /// - Parameter messageId: Message UUID
    /// - Returns: Render cache entity if exists
    public func getRenderCache(messageId: UUID) throws -> RenderCacheEntity? {
        try ensureOpen()
        
        let sql = """
            SELECT message_id, html_rendered, text_rendered, generated_at, generator_version
            FROM \(MailSchema.tRenderCache)
            WHERE message_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        let generatedAtEpoch = sqlite3_column_int64(stmt, 3)
        let generatedAt = Date(timeIntervalSince1970: TimeInterval(generatedAtEpoch))
        
        return RenderCacheEntity(
            messageId: stmt.columnUUID(0),
            htmlRendered: stmt.columnText(1),
            textRendered: stmt.columnText(2),
            generatedAt: generatedAt,
            generatorVersion: Int(sqlite3_column_int(stmt, 4))
        )
    }
    
    /// Check if render cache exists and is current
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - requiredVersion: Minimum generator version required
    /// - Returns: true if cache exists and is current
    public func hasValidRenderCache(messageId: UUID, requiredVersion: Int = 1) throws -> Bool {
        try ensureOpen()
        
        let sql = """
            SELECT 1 FROM \(MailSchema.tRenderCache)
            WHERE message_id = ? AND generator_version >= ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        bindInt(stmt, 2, requiredVersion)
        
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    
    // MARK: - Blob Store Metadata
    
    /// Get blob metadata
    /// - Parameter blobId: SHA256 hash
    /// - Returns: Blob store entity if exists
    public func getBlobMetadata(blobId: String) throws -> BlobStoreEntity? {
        try ensureOpen()
        
        let sql = """
            SELECT id, storage_path, size_bytes, ref_count, created_at
            FROM \(MailSchema.tBlobStore)
            WHERE id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        let createdAtEpoch = sqlite3_column_int64(stmt, 4)
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtEpoch))
        
        return BlobStoreEntity(
            id: stmt.columnText(0) ?? "",
            storagePath: stmt.columnText(1) ?? "",
            sizeBytes: Int(sqlite3_column_int(stmt, 2)),
            refCount: Int(sqlite3_column_int(stmt, 3)),
            createdAt: createdAt
        )
    }
    
    /// Get storage metrics
    /// - Returns: Storage metrics with deduplication stats
    public func getBlobStorageMetrics() throws -> BlobStorageMetrics {
        try ensureOpen()
        
        let sql = """
            SELECT 
                COUNT(*) as total_blobs,
                SUM(size_bytes) as total_size,
                SUM(CASE WHEN ref_count > 1 THEN size_bytes * (ref_count - 1) ELSE 0 END) as dedup_savings,
                SUM(CASE WHEN ref_count = 0 THEN 1 ELSE 0 END) as orphaned
            FROM \(MailSchema.tBlobStore)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return BlobStorageMetrics(totalBlobs: 0, totalSizeBytes: 0, uniqueBlobs: 0, 
                                     dedupSavingsBytes: 0, orphanedBlobs: 0)
        }
        
        let totalBlobs = Int(sqlite3_column_int(stmt, 0))
        let totalSize = Int(sqlite3_column_int64(stmt, 1))
        let dedupSavings = Int(sqlite3_column_int64(stmt, 2))
        let orphaned = Int(sqlite3_column_int(stmt, 3))
        
        return BlobStorageMetrics(
            totalBlobs: totalBlobs,
            totalSizeBytes: totalSize,
            uniqueBlobs: totalBlobs,
            dedupSavingsBytes: dedupSavings,
            orphanedBlobs: orphaned
        )
    }
}
