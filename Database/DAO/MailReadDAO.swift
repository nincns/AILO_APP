// AILO_APP/Core/Storage/MailReadDAO.swift
// Implementation of read-only mail data access operations
// Phase 2: Read operations layer

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol MailReadDAO {
    // Return headers for an account/folder with pagination  
    func headers(accountId: UUID, folder: String, limit: Int, offset: Int) throws -> [MailHeader]
    // Return body text or html (as a single preferred string) if available
    func body(accountId: UUID, folder: String, uid: String) throws -> String?
    // Return enhanced body entity with metadata
    func bodyEntity(accountId: UUID, folder: String, uid: String) throws -> MessageBodyEntity?
    // Strongly typed attachments
    func attachments(accountId: UUID, folder: String, uid: String) throws -> [AttachmentEntity]
    // Special folder mapping cache
    func specialFolders(accountId: UUID) throws -> [String: String]?
    func saveSpecialFolders(accountId: UUID, map: [String: String]) throws
    // UID management for sync
    func getLastSyncUID(accountId: UUID, folder: String) throws -> String?
}

// MARK: - Implementation

public class MailReadDAOImpl: BaseDAO, MailReadDAO {
    
    public override init(dbPath: String) {
        super.init(dbPath: dbPath)
    }
    
    // MARK: - Headers Query
    
    public func headers(accountId: UUID, folder: String, limit: Int, offset: Int) throws -> [MailHeader] {
        return try DAOPerformanceMonitor.measure("headers_query") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT uid, from_addr, subject, date, flags 
                    FROM \(MailSchema.tMsgHeader) 
                    WHERE account_id = ? AND folder = ? 
                    ORDER BY date DESC 
                    LIMIT ? OFFSET ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, folder)
                bindInt(stmt, 3, limit)
                bindInt(stmt, 4, offset)
                
                // UUID DEBUG LOGGING
                print("🔍 [MailReadDAO.UUID-DEBUG] READ Operation:")
                print("   - Query accountId: '\(accountId.uuidString)'")
                print("   - Query accountId.count: \(accountId.uuidString.count)")
                print("   - Contains dashes: \(accountId.uuidString.contains("-"))")
                print("   - Query folder: '\(folder)'")
                
                // DEBUG LOGGING
                print("🔍 [MailReadDAO] Executing headers query:")
                print("   - accountId: \(accountId.uuidString)")
                print("   - folder: \(folder)")
                print("   - limit: \(limit)")
                print("   - offset: \(offset)")
                
                var headers: [MailHeader] = []
                
                // ADDITIONAL DEBUG: Check what's actually in the database without WHERE clause
                print("🔍 [DEBUG-SCAN] Scanning ALL headers in database:")
                let scanSQL = """
                    SELECT account_id, folder, uid, subject 
                    FROM \(MailSchema.tMsgHeader) 
                    ORDER BY date DESC 
                    LIMIT 10
                """
                let scanStmt = try prepare(scanSQL)
                defer { finalize(scanStmt) }
                
                while sqlite3_step(scanStmt) == SQLITE_ROW {
                    let dbAccountId = scanStmt.columnText(0) ?? "NULL"
                    let dbFolder = scanStmt.columnText(1) ?? "NULL"
                    let dbUid = scanStmt.columnText(2) ?? "NULL"
                    let dbSubject = scanStmt.columnText(3) ?? "NULL"
                    print("   - DB: AccountId='\(dbAccountId)', Folder='\(dbFolder)', UID='\(dbUid)', Subject='\(dbSubject)'")
                }
                
                sqlite3_reset(stmt) // Reset the main statement
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let uid = stmt.columnText(0) ?? ""
                    let from = stmt.columnText(1) ?? ""
                    let subject = stmt.columnText(2) ?? ""
                    let date = stmt.columnDate(3)
                    let flags = stmt.columnStringArray(4)
                    
                    let header = MailHeader(id: uid, from: from, subject: subject, 
                                          date: date, flags: flags)
                    headers.append(header)
                }
                
                // DEBUG LOGGING
                print("🔍 [MailReadDAO] Query returned \(headers.count) headers")
                for (index, header) in headers.enumerated() {
                    print("   [\(index)] UID: \(header.id), Subject: \(header.subject)")
                }
                
                return headers
            }
        }
    }
    
    // MARK: - Body Query
    
    public func body(accountId: UUID, folder: String, uid: String) throws -> String? {
        return try DAOPerformanceMonitor.measure("body_query") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT html_body, text_body 
                    FROM \(MailSchema.tMsgBody) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, folder)
                bindText(stmt, 3, uid)
                
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    return nil
                }
                
                // Prefer HTML over text if available
                if let html = stmt.columnText(0), !html.isEmpty {
                    return html
                }
                
                return stmt.columnText(1)
            }
        }
    }
    
    // MARK: - Enhanced Body Entity
    
    public func bodyEntity(accountId: UUID, folder: String, uid: String) throws -> MessageBodyEntity? {
        return try DAOPerformanceMonitor.measure("body_entity_query") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT text_body, html_body, has_attachments, raw_body, content_type, charset, 
                           transfer_encoding, is_multipart, raw_size, processed_at
                    FROM \(MailSchema.tMsgBody) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, folder)
                bindText(stmt, 3, uid)
                
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    return nil
                }
                
                let text = stmt.columnText(0)
                let html = stmt.columnText(1)
                let hasAttachments = sqlite3_column_int(stmt, 2) != 0
                let rawBody = stmt.columnText(3)  // ✅ NEU
                let contentType = stmt.columnText(4)
                let charset = stmt.columnText(5)
                let transferEncoding = stmt.columnText(6)
                let isMultipart = sqlite3_column_int(stmt, 7) != 0
                let rawSize = stmt.columnIsNull(8) ? nil : stmt.columnInt(8)
                let processedAt = stmt.columnDate(9)
                
                // ✅ PHASE 2: RAW-first Loading - Debug Info
                print("✅ [MailReadDAO] bodyEntity loaded (RAW-first):")
                print("   - UID: \(uid)")
                print("   - text length: \(text?.count ?? 0)")
                print("   - html length: \(html?.count ?? 0)")
                print("   - rawBody length: \(rawBody?.count ?? 0)")
                print("   - rawBody available: \(rawBody != nil)")
                print("   - processedAt: \(processedAt?.description ?? "nil")")
                if let rawBody = rawBody {
                    print("   - rawBody preview: \(String(rawBody.prefix(200)))")
                }
                
                return MessageBodyEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: uid,
                    text: text,
                    html: html,
                    hasAttachments: hasAttachments,
                    rawBody: rawBody,  // ✅ NEU
                    contentType: contentType,
                    charset: charset,
                    transferEncoding: transferEncoding,
                    isMultipart: isMultipart,
                    rawSize: rawSize,
                    processedAt: processedAt
                )
            }
        }
    }
    
    // MARK: - Attachments Query
    
    public func attachments(accountId: UUID, folder: String, uid: String) throws -> [AttachmentEntity] {
        return try DAOPerformanceMonitor.measure("attachments_query") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT part_id, filename, mime_type, size_bytes, data,
                           content_id, is_inline, file_path, checksum
                    FROM \(MailSchema.tAttachment) 
                    WHERE account_id = ? AND folder = ? AND uid = ?
                    ORDER BY part_id
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, folder)
                bindText(stmt, 3, uid)
                
                var attachments: [AttachmentEntity] = []
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let partId = stmt.columnText(0) ?? ""
                    let filename = stmt.columnText(1) ?? ""
                    let mimeType = stmt.columnText(2) ?? ""
                    let sizeBytes = stmt.columnInt(3)
                    let data = stmt.columnBlob(4)
                    let contentId = stmt.columnText(5)
                    let isInline = sqlite3_column_int(stmt, 6) != 0
                    let filePath = stmt.columnText(7)
                    let checksum = stmt.columnText(8)
                    
                    let attachment = AttachmentEntity(
                        accountId: accountId,
                        folder: folder,
                        uid: uid,
                        partId: partId,
                        filename: filename,
                        mimeType: mimeType,
                        sizeBytes: sizeBytes,
                        data: data,
                        contentId: contentId,
                        isInline: isInline,
                        filePath: filePath,
                        checksum: checksum
                    )
                    attachments.append(attachment)
                }
                
                return attachments
            }
        }
    }
    
    // MARK: - Special Folders Cache
    
    public func specialFolders(accountId: UUID) throws -> [String: String]? {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT name, special_use 
                FROM \(MailSchema.tFolders) 
                WHERE account_id = ? AND special_use IS NOT NULL
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            
            var folderMap: [String: String] = [:]
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = stmt.columnText(0),
                   let specialUse = stmt.columnText(1) {
                    folderMap[specialUse] = name
                }
            }
            
            return folderMap.isEmpty ? nil : folderMap
        }
    }
    
    public func saveSpecialFolders(accountId: UUID, map: [String: String]) throws {
        print("🔧 DEBUG: saveSpecialFolders called for account: \(accountId)")
        print("🔧 DEBUG: Folder map: \(map)")
        
        try withTransaction {
            try ensureOpen()
            print("🔧 DEBUG: Database connection ensured")
            
            // Verify table exists using PRAGMA table_info (more reliable)
            let tableCheckSQL = "PRAGMA table_info(\(MailSchema.tFolders))"
            let checkStmt = try prepare(tableCheckSQL)
            defer { finalize(checkStmt) }
            
            let tableExists = sqlite3_step(checkStmt) == SQLITE_ROW
            print("🔧 DEBUG: Folders table exists check: \(tableExists)")
            
            if !tableExists {
                print("🔧 DEBUG: Folders table missing, creating it...")
                let createSQL = """
                    CREATE TABLE IF NOT EXISTS \(MailSchema.tFolders) (
                        account_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        special_use TEXT,
                        delimiter TEXT,
                        attributes TEXT,
                        PRIMARY KEY (account_id, name)
                    )
                """
                try exec(createSQL)
                print("🔧 DEBUG: Folders table created successfully")
            }
            
            // Clear existing mappings
            let clearSql = """
                UPDATE \(MailSchema.tFolders) 
                SET special_use = NULL 
                WHERE account_id = ?
            """
            
            print("🔧 DEBUG: Preparing clear statement...")
            let clearStmt = try prepare(clearSql)
            defer { finalize(clearStmt) }
            bindUUID(clearStmt, 1, accountId)
                
            print("🔧 DEBUG: Executing clear statement...")
            guard sqlite3_step(clearStmt) == SQLITE_DONE else {
                let error = String(cString: sqlite3_errmsg(self.db))
                print("❌ DEBUG: Clear failed: \(error)")
                throw DAOError.sqlError("Failed to clear special folder mappings: \(error)")
            }
            print("🔧 DEBUG: Clear completed successfully")
            
            // Set new mappings - but only if we have folders to map
            if !map.isEmpty {
                let updateSql = """
                    UPDATE \(MailSchema.tFolders) 
                    SET special_use = ? 
                    WHERE account_id = ? AND name = ?
                """
                
                print("🔧 DEBUG: Preparing update statement...")
                let updateStmt = try prepare(updateSql)
                defer { finalize(updateStmt) }
                
                for (specialUse, folderName) in map {
                    print("🔧 DEBUG: Updating folder '\(folderName)' with special use '\(specialUse)'")
                    sqlite3_reset(updateStmt)
                    bindText(updateStmt, 1, specialUse)
                    bindUUID(updateStmt, 2, accountId)
                    bindText(updateStmt, 3, folderName)
                    
                    guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                        let error = String(cString: sqlite3_errmsg(self.db))
                        print("❌ DEBUG: Update failed: \(error)")
                        throw DAOError.sqlError("Failed to update folder mapping: \(error)")
                    }
                }
            }
            print("🔧 DEBUG: All folder mappings updated successfully")
        }
        print("🔧 DEBUG: saveSpecialFolders completed successfully")
    }
    
    // MARK: - Sync UID Management
    
    public func getLastSyncUID(accountId: UUID, folder: String) throws -> String? {
        return try dbQueue.sync {
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
    }
}
