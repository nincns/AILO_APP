// AILO_APP/Core/Storage/StructuredMailStorage.swift
// Phase 4: Structured mail data storage implementation
// Three separate storage areas: Headers (fast), Bodies (on-demand), Attachments (deduplicated)
// Implements optimal database schema with indices and foreign keys

import Foundation
import SQLite3

// MARK: - Structured Mail Storage Implementation

/// Phase 4: Concrete implementation of structured mail storage
/// Separates data into three optimized storage areas for maximum performance
public actor StructuredMailStorage: MailHeaderStorage {
    private let databasePath: String
    private var db: OpaquePointer?
    
    public init(databasePath: String) {
        self.databasePath = databasePath
    }
    
    // MARK: - Database Initialization
    
    public func initialize() async throws {
        guard sqlite3_open(databasePath, &db) == SQLITE_OK else {
            throw StorageError.initializationFailed
        }
        
        try await createTables()
        try await createIndices()
    }
    
    private func createTables() async throws {
        // Phase 4: Create three separate, optimized tables
        
        // 1. Headers table - optimized for list display and searching
        let headersSQL = """
            CREATE TABLE IF NOT EXISTS mail_headers (
                account_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                uid TEXT NOT NULL,
                from_addr TEXT NOT NULL,
                subject TEXT NOT NULL,
                date_epoch INTEGER,
                flags TEXT, -- JSON array
                created_at INTEGER NOT NULL,
                PRIMARY KEY (account_id, folder, uid)
            );
        """
        
        // 2. Bodies table - lazy loaded content with full metadata
        let bodiesSQL = """
            CREATE TABLE IF NOT EXISTS mail_bodies (
                account_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                uid TEXT NOT NULL,
                text_content TEXT,
                html_content TEXT,
                has_attachments INTEGER NOT NULL DEFAULT 0,
                content_type TEXT,
                charset TEXT,
                transfer_encoding TEXT,
                is_multipart INTEGER NOT NULL DEFAULT 0,
                raw_size INTEGER,
                processed_at INTEGER,
                processing_warnings TEXT, -- JSON array
                raw_data_path TEXT, -- External storage for large bodies
                PRIMARY KEY (account_id, folder, uid),
                FOREIGN KEY (account_id, folder, uid) 
                    REFERENCES mail_headers(account_id, folder, uid)
            );
        """
        
        // 3. Attachments table - deduplicated with checksums
        let attachmentsSQL = """
            CREATE TABLE IF NOT EXISTS mail_attachments (
                id TEXT PRIMARY KEY, -- UUID
                account_id TEXT NOT NULL,
                folder TEXT NOT NULL,
                uid TEXT NOT NULL,
                part_id TEXT NOT NULL,
                filename TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                content_id TEXT, -- For inline attachments
                is_inline INTEGER NOT NULL DEFAULT 0,
                checksum TEXT NOT NULL, -- SHA256 for deduplication
                storage_path TEXT, -- External file storage path
                data BLOB, -- Optional: small attachments stored inline
                created_at INTEGER NOT NULL,
                FOREIGN KEY (account_id, folder, uid) 
                    REFERENCES mail_headers(account_id, folder, uid)
            );
        """
        
        for sql in [headersSQL, bodiesSQL, attachmentsSQL] {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw StorageError.tableCreationFailed
            }
        }
    }
    
    private func createIndices() async throws {
        // Phase 4: Optimized indices for each storage area
        let indices = [
            // Headers - optimized for list display and search
            "CREATE INDEX IF NOT EXISTS idx_headers_date ON mail_headers(account_id, folder, date_epoch DESC);",
            "CREATE INDEX IF NOT EXISTS idx_headers_search ON mail_headers(from_addr, subject);",
            "CREATE INDEX IF NOT EXISTS idx_headers_flags ON mail_headers(flags);",
            
            // Bodies - optimized for existence checks
            "CREATE INDEX IF NOT EXISTS idx_bodies_processed ON mail_bodies(processed_at);",
            "CREATE INDEX IF NOT EXISTS idx_bodies_size ON mail_bodies(raw_size);",
            
            // Attachments - optimized for deduplication and inline detection
            "CREATE INDEX IF NOT EXISTS idx_attachments_checksum ON mail_attachments(checksum);",
            "CREATE INDEX IF NOT EXISTS idx_attachments_inline ON mail_attachments(content_id) WHERE is_inline = 1;",
            "CREATE INDEX IF NOT EXISTS idx_attachments_size ON mail_attachments(size_bytes DESC);"
        ]
        
        for indexSQL in indices {
            guard sqlite3_exec(db, indexSQL, nil, nil, nil) == SQLITE_OK else {
                throw StorageError.indexCreationFailed
            }
        }
    }
    
    // MARK: - Phase 1: Header Management (Fast Access)
    
    public func getExistingUIDs(accountId: UUID, folder: String) async -> Set<String> {
        let sql = "SELECT uid FROM mail_headers WHERE account_id = ? AND folder = ?;"
        var statement: OpaquePointer?
        var uids: Set<String> = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return uids
        }
        
        sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, folder, -1, nil)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let uid = String(cString: sqlite3_column_text(statement, 0))
            uids.insert(uid)
        }
        
        sqlite3_finalize(statement)
        return uids
    }
    
    public func storeHeaders(_ headers: [MessageHeaderEntity]) async {
        let sql = """
            INSERT OR REPLACE INTO mail_headers 
            (account_id, folder, uid, from_addr, subject, date_epoch, flags, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        for header in headers {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            
            sqlite3_bind_text(statement, 1, header.accountId.uuidString, -1, nil)
            sqlite3_bind_text(statement, 2, header.folder, -1, nil)
            sqlite3_bind_text(statement, 3, header.uid, -1, nil)
            sqlite3_bind_text(statement, 4, header.from, -1, nil)
            sqlite3_bind_text(statement, 5, header.subject, -1, nil)
            sqlite3_bind_int64(statement, 6, Int64(header.date?.timeIntervalSince1970 ?? 0))
            
            // Serialize flags as JSON
            let flagsJSON = try? JSONSerialization.data(withJSONObject: header.flags)
            let flagsString = flagsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            sqlite3_bind_text(statement, 7, flagsString, -1, nil)
            
            sqlite3_bind_int64(statement, 8, Int64(Date().timeIntervalSince1970))
            
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
    
    public func updateFlags(accountId: UUID, folder: String, updates: [String: [String]]) async {
        let sql = "UPDATE mail_headers SET flags = ? WHERE account_id = ? AND folder = ? AND uid = ?;"
        
        for (uid, flags) in updates {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            
            let flagsJSON = try? JSONSerialization.data(withJSONObject: flags)
            let flagsString = flagsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            
            sqlite3_bind_text(statement, 1, flagsString, -1, nil)
            sqlite3_bind_text(statement, 2, accountId.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, folder, -1, nil)
            sqlite3_bind_text(statement, 4, uid, -1, nil)
            
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
    
    public func getHeaders(accountId: UUID, folder: String, limit: Int?, offset: Int?) async -> [MessageHeaderEntity] {
        var sql = """
            SELECT account_id, folder, uid, from_addr, subject, date_epoch, flags
            FROM mail_headers 
            WHERE account_id = ? AND folder = ?
            ORDER BY date_epoch DESC
        """
        
        if let limit = limit {
            sql += " LIMIT \(limit)"
            if let offset = offset {
                sql += " OFFSET \(offset)"
            }
        }
        
        var statement: OpaquePointer?
        var headers: [MessageHeaderEntity] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return headers
        }
        
        sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, folder, -1, nil)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let accountId = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) ?? UUID()
            let folder = String(cString: sqlite3_column_text(statement, 1))
            let uid = String(cString: sqlite3_column_text(statement, 2))
            let from = String(cString: sqlite3_column_text(statement, 3))
            let subject = String(cString: sqlite3_column_text(statement, 4))
            let dateEpoch = sqlite3_column_int64(statement, 5)
            let flagsString = String(cString: sqlite3_column_text(statement, 6))
            
            let date = dateEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(dateEpoch)) : nil
            let flags = (try? JSONSerialization.jsonObject(with: flagsString.data(using: .utf8) ?? Data()) as? [String]) ?? []
            
            let header = MessageHeaderEntity(
                accountId: accountId,
                folder: folder,
                uid: uid,
                from: from,
                subject: subject,
                date: date,
                flags: flags
            )
            headers.append(header)
        }
        
        sqlite3_finalize(statement)
        return headers
    }
    
    // MARK: - Phase 2: Body Management (On-Demand)
    
    public func getBody(accountId: UUID, folder: String, uid: String) async -> MessageBodyEntity? {
        let sql = """
            SELECT text_content, html_content, has_attachments, content_type, 
                   charset, transfer_encoding, is_multipart, raw_size, processed_at
            FROM mail_bodies 
            WHERE account_id = ? AND folder = ? AND uid = ?;
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, folder, -1, nil)
        sqlite3_bind_text(statement, 3, uid, -1, nil)
        
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        
        let text = sqlite3_column_text(statement, 0).flatMap { String(cString: $0) }
        let html = sqlite3_column_text(statement, 1).flatMap { String(cString: $0) }
        let hasAttachments = sqlite3_column_int(statement, 2) != 0
        let contentType = sqlite3_column_text(statement, 3).flatMap { String(cString: $0) }
        let charset = sqlite3_column_text(statement, 4).flatMap { String(cString: $0) }
        let transferEncoding = sqlite3_column_text(statement, 5).flatMap { String(cString: $0) }
        let isMultipart = sqlite3_column_int(statement, 6) != 0
        let rawSize = sqlite3_column_int(statement, 7)
        let processedAtEpoch = sqlite3_column_int64(statement, 8)
        
        let processedAt = processedAtEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(processedAtEpoch)) : nil
        
        return MessageBodyEntity(
            accountId: accountId,
            folder: folder,
            uid: uid,
            text: text,
            html: html,
            hasAttachments: hasAttachments,
            contentType: contentType,
            charset: charset,
            transferEncoding: transferEncoding,
            isMultipart: isMultipart,
            rawSize: rawSize > 0 ? Int(rawSize) : nil,
            processedAt: processedAt
        )
    }
    
    public func getBodies(accountId: UUID, folder: String, uids: [String]) async -> [MessageBodyEntity] {
        var bodies: [MessageBodyEntity] = []
        
        for uid in uids {
            if let body = await getBody(accountId: accountId, folder: folder, uid: uid) {
                bodies.append(body)
            }
        }
        
        return bodies
    }
    
    public func getMissingBodyUIDs(accountId: UUID, folder: String, uids: [String]) async -> [String] {
        guard !uids.isEmpty else { return [] }
        
        let placeholders = Array(repeating: "?", count: uids.count).joined(separator: ",")
        let sql = """
            SELECT h.uid FROM mail_headers h
            LEFT JOIN mail_bodies b ON h.account_id = b.account_id 
                                   AND h.folder = b.folder 
                                   AND h.uid = b.uid
            WHERE h.account_id = ? AND h.folder = ? AND h.uid IN (\(placeholders))
              AND b.uid IS NULL;
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        
        sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, folder, -1, nil)
        
        for (index, uid) in uids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 3), uid, -1, nil)
        }
        
        var missing: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let uid = String(cString: sqlite3_column_text(statement, 0))
            missing.append(uid)
        }
        
        sqlite3_finalize(statement)
        return missing
    }
    
    public func storeRawBody(_ body: MessageBodyEntity, rawData: String) async {
        let sql = """
            INSERT OR REPLACE INTO mail_bodies 
            (account_id, folder, uid, text_content, html_content, has_attachments,
             content_type, charset, transfer_encoding, is_multipart, raw_size, processed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        
        sqlite3_bind_text(statement, 1, body.accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, body.folder, -1, nil)
        sqlite3_bind_text(statement, 3, body.uid, -1, nil)
        sqlite3_bind_text(statement, 4, body.text, -1, nil)
        sqlite3_bind_text(statement, 5, body.html, -1, nil)
        sqlite3_bind_int(statement, 6, body.hasAttachments ? 1 : 0)
        sqlite3_bind_text(statement, 7, body.contentType, -1, nil)
        sqlite3_bind_text(statement, 8, body.charset, -1, nil)
        sqlite3_bind_text(statement, 9, body.transferEncoding, -1, nil)
        sqlite3_bind_int(statement, 10, body.isMultipart ? 1 : 0)
        sqlite3_bind_int(statement, 11, Int32(body.rawSize ?? 0))
        
        let processedAt = body.processedAt?.timeIntervalSince1970 ?? 0
        sqlite3_bind_int64(statement, 12, Int64(processedAt))
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    // MARK: - Phase 4: Attachment Management (Structured & Deduplicated)
    
    public func storeAttachments(_ attachments: [AttachmentEntity]) async {
        let sql = """
            INSERT OR REPLACE INTO mail_attachments 
            (id, account_id, folder, uid, part_id, filename, mime_type, size_bytes,
             content_id, is_inline, checksum, storage_path, data, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        
        for attachment in attachments {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            
            let id = UUID().uuidString
            sqlite3_bind_text(statement, 1, id, -1, nil)
            sqlite3_bind_text(statement, 2, attachment.accountId.uuidString, -1, nil)
            sqlite3_bind_text(statement, 3, attachment.folder, -1, nil)
            sqlite3_bind_text(statement, 4, attachment.uid, -1, nil)
            sqlite3_bind_text(statement, 5, attachment.partId, -1, nil)
            sqlite3_bind_text(statement, 6, attachment.filename, -1, nil)
            sqlite3_bind_text(statement, 7, attachment.mimeType, -1, nil)
            sqlite3_bind_int(statement, 8, Int32(attachment.sizeBytes))
            sqlite3_bind_text(statement, 9, attachment.contentId, -1, nil)
            sqlite3_bind_int(statement, 10, attachment.isInline ? 1 : 0)
            sqlite3_bind_text(statement, 11, attachment.checksum, -1, nil)
            sqlite3_bind_text(statement, 12, attachment.filePath, -1, nil)
            
            if let data = attachment.data {
                sqlite3_bind_blob(statement, 13, data.withUnsafeBytes { $0.bindMemory(to: Int8.self).baseAddress }, Int32(data.count), nil)
            }
            
            sqlite3_bind_int64(statement, 14, Int64(Date().timeIntervalSince1970))
            
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
    
    public func getAttachments(accountId: UUID, folder: String, uid: String) async -> [AttachmentEntity] {
        let sql = """
            SELECT part_id, filename, mime_type, size_bytes, content_id, 
                   is_inline, checksum, storage_path, data
            FROM mail_attachments 
            WHERE account_id = ? AND folder = ? AND uid = ?
            ORDER BY part_id;
        """
        
        var statement: OpaquePointer?
        var attachments: [AttachmentEntity] = []
        
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return attachments
        }
        
        sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
        sqlite3_bind_text(statement, 2, folder, -1, nil)
        sqlite3_bind_text(statement, 3, uid, -1, nil)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            let partId = String(cString: sqlite3_column_text(statement, 0))
            let filename = String(cString: sqlite3_column_text(statement, 1))
            let mimeType = String(cString: sqlite3_column_text(statement, 2))
            let sizeBytes = Int(sqlite3_column_int(statement, 3))
            let contentId = sqlite3_column_text(statement, 4).flatMap { String(cString: $0) }
            let isInline = sqlite3_column_int(statement, 5) != 0
            let checksum = sqlite3_column_text(statement, 6).flatMap { String(cString: $0) }
            let storagePath = sqlite3_column_text(statement, 7).flatMap { String(cString: $0) }
            
            var data: Data?
            if let blob = sqlite3_column_blob(statement, 8) {
                let size = sqlite3_column_bytes(statement, 8)
                data = Data(bytes: blob, count: Int(size))
            }
            
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
                filePath: storagePath,
                checksum: checksum
            )
            
            attachments.append(attachment)
        }
        
        sqlite3_finalize(statement)
        return attachments
    }
    
    public func getAttachmentByChecksum(_ checksum: String) async -> AttachmentEntity? {
        let sql = """
            SELECT account_id, folder, uid, part_id, filename, mime_type, 
                   size_bytes, content_id, is_inline, storage_path, data
            FROM mail_attachments 
            WHERE checksum = ?
            LIMIT 1;
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, checksum, -1, nil)
        
        defer { sqlite3_finalize(statement) }
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        
        let accountId = UUID(uuidString: String(cString: sqlite3_column_text(statement, 0))) ?? UUID()
        let folder = String(cString: sqlite3_column_text(statement, 1))
        let uid = String(cString: sqlite3_column_text(statement, 2))
        let partId = String(cString: sqlite3_column_text(statement, 3))
        let filename = String(cString: sqlite3_column_text(statement, 4))
        let mimeType = String(cString: sqlite3_column_text(statement, 5))
        let sizeBytes = Int(sqlite3_column_int(statement, 6))
        let contentId = sqlite3_column_text(statement, 7).flatMap { String(cString: $0) }
        let isInline = sqlite3_column_int(statement, 8) != 0
        let storagePath = sqlite3_column_text(statement, 9).flatMap { String(cString: $0) }
        
        var data: Data?
        if let blob = sqlite3_column_blob(statement, 10) {
            let size = sqlite3_column_bytes(statement, 10)
            data = Data(bytes: blob, count: Int(size))
        }
        
        return AttachmentEntity(
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
            filePath: storagePath,
            checksum: checksum
        )
    }
    
    public func deduplicateAttachments() async -> Int {
        // Find and remove duplicate attachments based on checksum
        let sql = """
            DELETE FROM mail_attachments 
            WHERE id NOT IN (
                SELECT MIN(id) 
                FROM mail_attachments 
                GROUP BY checksum
            ) AND checksum IS NOT NULL;
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        
        sqlite3_step(statement)
        let deletedCount = sqlite3_changes(db)
        sqlite3_finalize(statement)
        
        return Int(deletedCount)
    }
    
    // MARK: - Phase 5: Bidirectional Sync Support
    
    public func removeMessages(accountId: UUID, folder: String, uids: [String]) async {
        guard !uids.isEmpty else { return }
        
        let placeholders = Array(repeating: "?", count: uids.count).joined(separator: ",")
        
        // Remove from all three tables (cascading delete)
        let sqls = [
            "DELETE FROM mail_attachments WHERE account_id = ? AND folder = ? AND uid IN (\(placeholders));",
            "DELETE FROM mail_bodies WHERE account_id = ? AND folder = ? AND uid IN (\(placeholders));",
            "DELETE FROM mail_headers WHERE account_id = ? AND folder = ? AND uid IN (\(placeholders));"
        ]
        
        for sql in sqls {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                continue
            }
            
            sqlite3_bind_text(statement, 1, accountId.uuidString, -1, nil)
            sqlite3_bind_text(statement, 2, folder, -1, nil)
            
            for (index, uid) in uids.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 3), uid, -1, nil)
            }
            
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    deinit {
        sqlite3_close(db)
    }
}

// MARK: - Storage Errors

public enum StorageError: Error, LocalizedError {
    case initializationFailed
    case tableCreationFailed
    case indexCreationFailed
    
    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            return "Database initialization failed"
        case .tableCreationFailed:
            return "Table creation failed"
        case .indexCreationFailed:
            return "Index creation failed"
        }
    }
}