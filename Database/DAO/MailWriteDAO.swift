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
    
    // Body operations  
    func storeBody(accountId: UUID, folder: String, uid: String, body: MessageBodyEntity) throws
    
    // Attachment operations
    func storeAttachment(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws
    
    // Sync management
    func updateLastSyncUID(accountId: UUID, folder: String, uid: String) throws
    func getLastSyncUID(accountId: UUID, folder: String) throws -> String?
    
    // Cleanup operations
    func deleteMessage(accountId: UUID, folder: String, uid: String) throws
    func purgeFolder(accountId: UUID, folder: String) throws
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
                
                // UUID DEBUG LOGGING
                print("🔍 [MailWriteDAO.UUID-DEBUG] WRITE Operation:")
                print("   - accountId: '\(accountId.uuidString)'")
                print("   - accountId.count: \(accountId.uuidString.count)")
                print("   - Contains dashes: \(accountId.uuidString.contains("-"))")
                print("   - folder: '\(folder)'")
                
                // DEBUG LOGGING
                print("🔍 [MailWriteDAO] Inserting \(headers.count) headers:")
                for header in headers {
                    print("   - UID: \(header.id), Subject: \(header.subject)")
                }
                
                for header in headers {
                    sqlite3_reset(stmt)
                    
                    bindUUID(stmt, 1, accountId)
                    bindText(stmt, 2, folder)
                    bindText(stmt, 3, header.id)
                    bindText(stmt, 4, header.from)
                    bindText(stmt, 5, header.subject)
                    bindDate(stmt, 6, header.date)
                    bindStringArray(stmt, 7, header.flags)
                    
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DAOError.sqlError("Failed to insert header for uid: \(header.id)")
                    }
                    print("   ✅ Inserted UID: \(header.id)")
                }
                
                // IMMEDIATE VERIFICATION: Check what was actually written
                let verifySQL = """
                    SELECT account_id, uid, subject FROM \(MailSchema.tMsgHeader) 
                    WHERE account_id = ? AND folder = ?
                """
                let verifyStmt = try prepare(verifySQL)
                defer { finalize(verifyStmt) }
                
                bindUUID(verifyStmt, 1, accountId)
                bindText(verifyStmt, 2, folder)
                
                print("🔍 [VERIFY] All rows in DB after insert:")
                while sqlite3_step(verifyStmt) == SQLITE_ROW {
                    let dbAccountId = verifyStmt.columnText(0) ?? "NULL"
                    let dbUid = verifyStmt.columnText(1) ?? "NULL"
                    let dbSubject = verifyStmt.columnText(2) ?? "NULL"
                    
                    print("   - AccountId: '\(dbAccountId)'")
                    print("   - UID: '\(dbUid)'")
                    print("   - Subject: '\(dbSubject)'")
                    print("   - Match: \(dbAccountId == accountId.uuidString)")
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
                
                // UUID DEBUG LOGGING
                print("🔍 [MailWriteDAO.UUID-DEBUG] UPSERT Operation:")
                print("   - accountId: '\(accountId.uuidString)'")
                print("   - accountId.count: \(accountId.uuidString.count)")
                print("   - Contains dashes: \(accountId.uuidString.contains("-"))")
                print("   - folder: '\(folder)'")
                
                // DEBUG LOGGING
                print("🔍 [MailWriteDAO] Upserting \(headers.count) headers:")
                for header in headers {
                    print("   - UID: \(header.id), Subject: \(header.subject)")
                }
                
                for header in headers {
                    sqlite3_reset(stmt)
                    
                    bindUUID(stmt, 1, accountId)
                    bindText(stmt, 2, folder)
                    bindText(stmt, 3, header.id)
                    bindText(stmt, 4, header.from)
                    bindText(stmt, 5, header.subject)
                    bindDate(stmt, 6, header.date)
                    bindStringArray(stmt, 7, header.flags)
                    
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DAOError.sqlError("Failed to upsert header for uid: \(header.id)")
                    }
                    print("   ✅ Upserted UID: \(header.id)")
                }
                
                // IMMEDIATE VERIFICATION: Check what was actually written
                let verifySQL = """
                    SELECT account_id, uid, subject FROM \(MailSchema.tMsgHeader) 
                    WHERE account_id = ? AND folder = ?
                """
                let verifyStmt = try prepare(verifySQL)
                defer { finalize(verifyStmt) }
                
                bindUUID(verifyStmt, 1, accountId)
                bindText(verifyStmt, 2, folder)
                
                print("🔍 [VERIFY-UPSERT] All rows in DB after upsert:")
                while sqlite3_step(verifyStmt) == SQLITE_ROW {
                    let dbAccountId = verifyStmt.columnText(0) ?? "NULL"
                    let dbUid = verifyStmt.columnText(1) ?? "NULL" 
                    let dbSubject = verifyStmt.columnText(2) ?? "NULL"
                    
                    print("   - AccountId: '\(dbAccountId)'")
                    print("   - UID: '\(dbUid)'")
                    print("   - Subject: '\(dbSubject)'")
                    print("   - Match: \(dbAccountId == accountId.uuidString)")
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
                (account_id, folder, uid, text_body, html_body, has_attachments, 
                 content_type, charset, transfer_encoding, is_multipart, 
                 raw_size, processed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, folder)
            bindText(stmt, 3, uid)
            bindText(stmt, 4, body.text)
            bindText(stmt, 5, body.html)
            sqlite3_bind_int(stmt, 6, body.hasAttachments ? 1 : 0)
            bindText(stmt, 7, body.contentType)
            bindText(stmt, 8, body.charset)
            bindText(stmt, 9, body.transferEncoding)
            sqlite3_bind_int(stmt, 10, body.isMultipart ? 1 : 0)
            bindInt(stmt, 11, body.rawSize)
            bindDate(stmt, 12, body.processedAt)
            
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
}
