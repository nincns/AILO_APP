// AILO_APP/Core/Storage/MailWriteDAO.swift
// Implementation of write mail data access operations
// Phase 2: Write operations layer

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol MailWriteDAO {
    // Header operations
    func insertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws
    func upsertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws

    // Flag operations
    func updateFlags(accountId: UUID, folder: String, uid: String, flags: [String]) throws
    
    // Body operations  
    func storeBody(accountId: UUID, folder: String, uid: String, body: MessageBodyEntity) throws
    
    // Attachment operations
    func storeAttachment(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws
    func updateAttachmentStatus(accountId: UUID, folder: String, uid: String, partId: String, status: String) throws
    func updateVirusScanStatus(accountId: UUID, folder: String, uid: String, partId: String, scanResult: String) throws
    
    // MIME Parts operations
    func storeMimeParts(_ parts: [MimePartEntity]) throws
    func deleteMimeParts(messageId: UUID) throws
    func updateMimePartBlobId(messageId: UUID, partId: String, blobId: String) throws
    
    // Render Cache operations
    func storeRenderCache(messageId: UUID, html: String?, text: String?, generatorVersion: Int) throws
    func invalidateRenderCache(messageId: UUID) throws
    
    // Blob Meta operations
    func storeBlobMeta(blobId: String, hashSha256: String, sizeBytes: Int) throws
    func updateBlobAccess(blobId: String) throws
    
    // Message Updates
    func updateRawBlobId(messageId: UUID, blobId: String) throws
    func updateMessageMetadata(messageId: UUID, hasAttachments: Bool, sizeTotal: Int) throws
    
    // Sync management
    func updateLastSyncUID(accountId: UUID, folder: String, uid: String) throws
    func getLastSyncUID(accountId: UUID, folder: String) throws -> String?
    
    // Cleanup operations
    func deleteMessage(accountId: UUID, folder: String, uid: String) throws
    func purgeFolder(accountId: UUID, folder: String) throws
    
    // Blob reference management
    func incrementBlobReference(_ blobId: String) throws
    func decrementBlobReference(_ blobId: String) throws
    func deleteBlobMeta(_ blobId: String) throws
}

// Combined protocol for full access
public protocol MailFullAccessDAO: MailReadDAO, MailWriteDAO {}

// MARK: - Implementation

public class MailWriteDAOImpl: BaseDAO, MailWriteDAO {
    
    public override init(dbPath: String) {
        super.init(dbPath: dbPath)
    }
    
    // MARK: - Header Operations
    
    public func insertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws {
        guard !headers.isEmpty else { return }

        try DAOPerformanceMonitor.measure("insert_headers") {
            try withTransaction {
                try ensureOpen()

                let sql = """
                    INSERT OR IGNORE INTO \(MailSchema.tMsgHeader)
                    (account_id, folder, uid, from_addr, subject, date, flags)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """

                let stmt = try prepare(sql)
                defer { finalize(stmt) }

                for header in headers {
                    sqlite3_clear_bindings(stmt)
                    sqlite3_reset(stmt)

                    bindUUID(stmt, 1, accountId)
                    bindText(stmt, 2, folder)
                    bindText(stmt, 3, header.id)
                    bindText(stmt, 4, header.from)
                    bindText(stmt, 5, header.subject)
                    bindDate(stmt, 6, header.date)
                    bindStringArray(stmt, 7, header.flags)

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        let errorMsg = String(cString: sqlite3_errmsg(db))
                        throw DAOError.sqlError("Failed to insert header for uid: \(header.id), SQLite error: \(errorMsg)")
                    }
                }
            }
        }
    }
    
    public func upsertHeaders(accountId: UUID, folder: String, headers: [MailHeader]) throws {
        guard !headers.isEmpty else { return }

        try DAOPerformanceMonitor.measure("upsert_headers") {
            try withTransaction {
                try ensureOpen()

                let sql = """
                    INSERT OR REPLACE INTO \(MailSchema.tMsgHeader)
                    (account_id, folder, uid, from_addr, subject, date, flags)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """

                let stmt = try prepare(sql)
                defer { finalize(stmt) }

                for header in headers {
                    sqlite3_clear_bindings(stmt)
                    sqlite3_reset(stmt)

                    bindUUID(stmt, 1, accountId)
                    bindText(stmt, 2, folder)
                    bindText(stmt, 3, header.id)
                    bindText(stmt, 4, header.from)
                    bindText(stmt, 5, header.subject)
                    bindDate(stmt, 6, header.date)
                    bindStringArray(stmt, 7, header.flags)

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        let errorMsg = String(cString: sqlite3_errmsg(db))
                        throw DAOError.sqlError("Failed to upsert header for uid: \(header.id), SQLite error: \(errorMsg)")
                    }
                }
            }
        }
    }
    
    // MARK: - Body Operations
    
    public func storeBody(accountId: UUID, folder: String, uid: String, body: MessageBodyEntity) throws {
        try DAOPerformanceMonitor.measure("store_body") {
            try ensureOpen()
            
            let sql = """
                INSERT OR REPLACE INTO \(MailSchema.tMsgBody)
                (account_id, folder, uid, text_body, html_body, has_attachments, raw_body,
                 content_type, charset, transfer_encoding, is_multipart, 
                 raw_size, processed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, folder)
            bindText(stmt, 3, uid)
            bindText(stmt, 4, body.text)
            bindText(stmt, 5, body.html)
            sqlite3_bind_int(stmt, 6, body.hasAttachments ? 1 : 0)
            bindText(stmt, 7, body.rawBody)  // ✅ NEU
            bindText(stmt, 8, body.contentType)
            bindText(stmt, 9, body.charset)
            bindText(stmt, 10, body.transferEncoding)
            sqlite3_bind_int(stmt, 11, body.isMultipart ? 1 : 0)
            bindInt(stmt, 12, body.rawSize)
            bindDate(stmt, 13, body.processedAt)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to store body for uid: \(uid)")
            }
        }
    }
    
    // MARK: - Attachment Operations
    
    public func storeAttachment(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws {
        try DAOPerformanceMonitor.measure("store_attachment") {
            try ensureOpen()
            
            let sql = """
                INSERT OR REPLACE INTO \(MailSchema.tAttachment)
                (account_id, folder, uid, part_id, filename, mime_type, size_bytes, 
                 data, content_id, is_inline, file_path, checksum)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, folder)
            bindText(stmt, 3, uid)
            bindText(stmt, 4, attachment.partId)
            bindText(stmt, 5, attachment.filename)
            bindText(stmt, 6, attachment.mimeType)
            bindInt(stmt, 7, attachment.sizeBytes)
            bindBlob(stmt, 8, attachment.data)
            bindText(stmt, 9, attachment.contentId)
            sqlite3_bind_int(stmt, 10, attachment.isInline ? 1 : 0)
            bindText(stmt, 11, attachment.filePath)
            bindText(stmt, 12, attachment.checksum)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to store attachment: \(attachment.partId)")
            }
        }
    }
    
    // MARK: - Phase 1: MIME Parts Schreib-Operationen
    
    public func storeMimeParts(_ parts: [MimePartEntity]) throws {
        guard !parts.isEmpty else { return }
        
        try ensureOpen()
        
        let sql = """
            INSERT OR REPLACE INTO \(MailSchema.tMimeParts)
            (id, message_id, part_number, content_type, content_subtype, content_id, content_disposition, 
             filename, size, encoding, charset, is_attachment, is_inline, parent_part_number)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        for part in parts {
            bindUUID(stmt, 1, part.id)
            bindUUID(stmt, 2, part.messageId)
            bindText(stmt, 3, part.partNumber)
            bindText(stmt, 4, part.contentType)
            bindText(stmt, 5, part.contentSubtype)
            bindText(stmt, 6, part.contentId)
            bindText(stmt, 7, part.contentDisposition)
            bindText(stmt, 8, part.filename)
            bindInt64(stmt, 9, part.size)
            bindText(stmt, 10, part.encoding)
            bindText(stmt, 11, part.charset)
            bindBool(stmt, 12, part.isAttachment)
            bindBool(stmt, 13, part.isInline)
            bindText(stmt, 14, part.parentPartNumber)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "storeMimeParts")
            }
            sqlite3_reset(stmt)
        }
    }
    
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
    
    // MARK: - Phase 1: Render Cache Schreib-Operationen
    
    public func storeRenderCache(messageId: UUID, html: String?, text: String?, generatorVersion: Int) throws {
        try ensureOpen()
        
        let sql = """
            INSERT OR REPLACE INTO \(MailSchema.tRenderCache)
            (message_id, html_rendered, text_rendered, generated_at, generator_version)
            VALUES (?, ?, ?, ?, ?)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        bindText(stmt, 2, html)
        bindText(stmt, 3, text)
        bindInt(stmt, 4, Int(Date().timeIntervalSince1970))
        bindInt(stmt, 5, generatorVersion)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "storeRenderCache")
        }
    }
    
    public func invalidateRenderCache(messageId: UUID) throws {
        try ensureOpen()
        
        let sql = "DELETE FROM \(MailSchema.tRenderCache) WHERE message_id = ?"
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, messageId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "invalidateRenderCache")
        }
    }
    
    // MARK: - Phase 1: Blob Meta Schreib-Operationen
    
    public func storeBlobMeta(blobId: String, hashSha256: String, sizeBytes: Int) throws {
        try ensureOpen()
        
        let sql = """
            INSERT OR REPLACE INTO \(MailSchema.tBlobMeta)
            (blob_id, hash_sha256, size_bytes, reference_count, created_at)
            VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(blob_id) DO UPDATE SET
            reference_count = reference_count + 1,
            last_accessed = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        let now = Int(Date().timeIntervalSince1970)
        
        bindText(stmt, 1, blobId)
        bindText(stmt, 2, hashSha256)
        bindInt(stmt, 3, sizeBytes)
        bindInt(stmt, 4, now)
        bindInt(stmt, 5, now)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "storeBlobMeta")
        }
    }
    
    public func updateBlobAccess(blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tBlobMeta)
            SET last_accessed = ?
            WHERE blob_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindInt(stmt, 1, Int(Date().timeIntervalSince1970))
        bindText(stmt, 2, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateBlobAccess")
        }
    }
    
    // MARK: - Phase 1: RAW Message Blob Updates
    
    public func updateRawBlobId(messageId: UUID, blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE messages 
            SET raw_rfc822_blob_id = ?
            WHERE id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        bindUUID(stmt, 2, messageId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateRawBlobId")
        }
    }
    
    // MARK: - Phase 1: Message Metadata Updates
    
    public func updateMessageMetadata(messageId: UUID, hasAttachments: Bool, sizeTotal: Int) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE messages 
            SET has_attachments = ?, size_total = ?
            WHERE id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindBool(stmt, 1, hasAttachments)
        bindInt(stmt, 2, sizeTotal)
        bindUUID(stmt, 3, messageId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateMessageMetadata")
        }
    }
    
    // MARK: - Phase 6: Erweiterte Attachment-Updates
    
    public func updateAttachmentStatus(accountId: UUID, folder: String, uid: String, partId: String, status: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tAttachment)
            SET status = ?
            WHERE account_id = ? AND folder = ? AND uid = ? AND part_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, status)
        bindUUID(stmt, 2, accountId)
        bindText(stmt, 3, folder)
        bindText(stmt, 4, uid)
        bindText(stmt, 5, partId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateAttachmentStatus")
        }
    }
    
    public func updateVirusScanStatus(accountId: UUID, folder: String, uid: String, partId: String, scanResult: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tAttachment)
            SET virus_scanned = ?
            WHERE account_id = ? AND folder = ? AND uid = ? AND part_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, scanResult)
        bindUUID(stmt, 2, accountId)
        bindText(stmt, 3, folder)
        bindText(stmt, 4, uid)
        bindText(stmt, 5, partId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateVirusScanStatus")
        }
    }
    
    // MARK: - Phase 3: Batch Operations
    
    public func updateMimePartBlobId(messageId: UUID, partId: String, blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tMimeParts)
            SET blob_id = ?
            WHERE message_id = ? AND part_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        bindUUID(stmt, 2, messageId)
        bindText(stmt, 3, partId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "updateMimePartBlobId")
        }
    }
    
    // MARK: - Sync Management
    
    public func updateLastSyncUID(accountId: UUID, folder: String, uid: String) throws {
        // This is handled by tracking the highest UID in headers table
        // No separate sync table needed for this implementation
    }
    
    public func getLastSyncUID(accountId: UUID, folder: String) throws -> String? {
        try ensureOpen()
        
        let sql = """
            SELECT MAX(uid) 
            FROM \(MailSchema.tMsgHeader) 
            WHERE account_id = ? AND folder = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindUUID(stmt, 1, accountId)
        bindText(stmt, 2, folder)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return stmt.columnText(0)
    }
    
    // MARK: - Cleanup Operations
    
    public func deleteMessage(accountId: UUID, folder: String, uid: String) throws {
        try DAOPerformanceMonitor.measure("delete_message") {
            try withTransaction {
                try ensureOpen()
                
                // Delete attachments first
                let deleteAttachmentsSql = """
                    DELETE FROM \(MailSchema.tAttachment) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                """
                
                let attachmentsStmt = try prepare(deleteAttachmentsSql)
                defer { finalize(attachmentsStmt) }
                
                bindUUID(attachmentsStmt, 1, accountId)
                bindText(attachmentsStmt, 2, folder)
                bindText(attachmentsStmt, 3, uid)
                
                sqlite3_step(attachmentsStmt)
                
                // Delete body
                let deleteBodySql = """
                    DELETE FROM \(MailSchema.tMsgBody) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                """
                
                let bodyStmt = try prepare(deleteBodySql)
                defer { finalize(bodyStmt) }
                
                bindUUID(bodyStmt, 1, accountId)
                bindText(bodyStmt, 2, folder)
                bindText(bodyStmt, 3, uid)
                
                sqlite3_step(bodyStmt)
                
                // Delete header last
                let deleteHeaderSql = """
                    DELETE FROM \(MailSchema.tMsgHeader) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                """
                
                let headerStmt = try prepare(deleteHeaderSql)
                defer { finalize(headerStmt) }
                
                bindUUID(headerStmt, 1, accountId)
                bindText(headerStmt, 2, folder)
                bindText(headerStmt, 3, uid)
                
                guard sqlite3_step(headerStmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to delete message: \(uid)")
                }
            }
        }
    }
    
    public func purgeFolder(accountId: UUID, folder: String) throws {
        try DAOPerformanceMonitor.measure("purge_folder") {
            try withTransaction {
                try ensureOpen()
                
                // Delete all attachments for this folder
                let deleteAttachmentsSql = """
                    DELETE FROM \(MailSchema.tAttachment) 
                    WHERE account_id = ? AND folder = ?
                """
                
                let attachmentsStmt = try prepare(deleteAttachmentsSql)
                defer { finalize(attachmentsStmt) }
                
                bindUUID(attachmentsStmt, 1, accountId)
                bindText(attachmentsStmt, 2, folder)
                
                sqlite3_step(attachmentsStmt)
                
                // Delete all bodies for this folder
                let deleteBodySql = """
                    DELETE FROM \(MailSchema.tMsgBody) 
                    WHERE account_id = ? AND folder = ?
                """
                
                let bodyStmt = try prepare(deleteBodySql)
                defer { finalize(bodyStmt) }
                
                bindUUID(bodyStmt, 1, accountId)
                bindText(bodyStmt, 2, folder)
                
                sqlite3_step(bodyStmt)
                
                // Delete all headers for this folder
                let deleteHeadersSql = """
                    DELETE FROM \(MailSchema.tMsgHeader) 
                    WHERE account_id = ? AND folder = ?
                """
                
                let headersStmt = try prepare(deleteHeadersSql)
                defer { finalize(headersStmt) }
                
                bindUUID(headersStmt, 1, accountId)
                bindText(headersStmt, 2, folder)
                
                guard sqlite3_step(headersStmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to purge folder: \(folder)")
                }
            }
        }
    }
    
    // MARK: - Blob Reference Management
    
    public func incrementBlobReference(_ blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tBlobMeta)
            SET reference_count = reference_count + 1,
                last_accessed = ?
            WHERE blob_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindInt(stmt, 1, Int(Date().timeIntervalSince1970))
        bindText(stmt, 2, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "incrementBlobReference")
        }
    }
    
    public func decrementBlobReference(_ blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE \(MailSchema.tBlobMeta)
            SET reference_count = reference_count - 1
            WHERE blob_id = ? AND reference_count > 0
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "decrementBlobReference")
        }
    }
    
    public func deleteBlobMeta(_ blobId: String) throws {
        try ensureOpen()

        let sql = "DELETE FROM \(MailSchema.tBlobMeta) WHERE blob_id = ?"

        let stmt = try prepare(sql)
        defer { finalize(stmt) }

        bindText(stmt, 1, blobId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "deleteBlobMeta")
        }
    }

    // MARK: - Flag Operations

    /// Update flags for a specific message in the database
    /// This is called after successfully updating flags on the IMAP server
    public func updateFlags(accountId: UUID, folder: String, uid: String, flags: [String]) throws {
        try DAOPerformanceMonitor.measure("update_flags") {
            try ensureOpen()

            let sql = """
                UPDATE \(MailSchema.tMsgHeader)
                SET flags = ?
                WHERE account_id = ? AND folder = ? AND uid = ?
            """

            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindStringArray(stmt, 1, flags)
            bindUUID(stmt, 2, accountId)
            bindText(stmt, 3, folder)
            bindText(stmt, 4, uid)

            let result = sqlite3_step(stmt)
            guard result == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update flags for uid: \(uid)")
            }
        }
    }
}
