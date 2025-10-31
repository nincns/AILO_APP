// AILO_APP/Core/Storage/AttachmentDAO.swift
// Specialized attachment management with file storage and deduplication
// Phase 3: Attachment operations layer

import Foundation
import SQLite3
import CryptoKit

// MARK: - Protocol Definition

public protocol AttachmentDAO {
    // Core attachment operations
    func store(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws
    func get(accountId: UUID, folder: String, uid: String, partId: String) throws -> AttachmentEntity?
    func getAll(accountId: UUID, folder: String, uid: String) throws -> [AttachmentEntity]
    
    // File-based storage operations
    func migrateToFileStorage(attachment: AttachmentEntity) throws -> AttachmentEntity
    func getAttachmentData(attachment: AttachmentEntity) throws -> Data?
    
    // Deduplication and cleanup
    func deduplicateAttachment(attachment: AttachmentEntity) throws -> AttachmentEntity
    func cleanupOrphanedFiles() throws
    func getStorageMetrics() throws -> AttachmentStorageMetrics
}

// MARK: - Supporting Types

public struct AttachmentStorageMetrics: Sendable {
    public let totalAttachments: Int
    public let dbStoredCount: Int
    public let fileStoredCount: Int
    public let totalSizeBytes: Int64
    public let duplicateCount: Int
    
    public init(totalAttachments: Int, dbStoredCount: Int, fileStoredCount: Int, 
                totalSizeBytes: Int64, duplicateCount: Int) {
        self.totalAttachments = totalAttachments
        self.dbStoredCount = dbStoredCount
        self.fileStoredCount = fileStoredCount
        self.totalSizeBytes = totalSizeBytes
        self.duplicateCount = duplicateCount
    }
}

// MARK: - Implementation

public class AttachmentDAOImpl: BaseDAO, AttachmentDAO {
    
    // MARK: - Configuration
    
    private let attachmentsDirectory: URL
    private let maxInlineSize: Int
    private let deduplicationEnabled: Bool
    
    public init(dbPath: String, attachmentsDirectory: URL, maxInlineSize: Int = 1024 * 1024, 
                deduplicationEnabled: Bool = true) {
        self.attachmentsDirectory = attachmentsDirectory
        self.maxInlineSize = maxInlineSize
        self.deduplicationEnabled = deduplicationEnabled
        super.init(dbPath: dbPath)
        
        // Ensure attachments directory exists
        try? FileManager.default.createDirectory(at: attachmentsDirectory, 
                                               withIntermediateDirectories: true)
    }
    
    // MARK: - Core Operations
    
    public func store(accountId: UUID, folder: String, uid: String, attachment: AttachmentEntity) throws {
        try DAOPerformanceMonitor.measure("store_attachment") {
            var processedAttachment = attachment
            
            // Apply deduplication if enabled
            if deduplicationEnabled && attachment.data != nil {
                processedAttachment = try deduplicateAttachment(attachment: attachment)
            }
            
            // Decide storage strategy based on size and type
            if let data = processedAttachment.data, 
               data.count > maxInlineSize && !processedAttachment.isInline {
                processedAttachment = try migrateToFileStorage(attachment: processedAttachment)
            }
            
            try dbQueue.sync {
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
                bindText(stmt, 4, processedAttachment.partId)
                bindText(stmt, 5, processedAttachment.filename)
                bindText(stmt, 6, processedAttachment.mimeType)
                bindInt(stmt, 7, processedAttachment.sizeBytes)
                bindBlob(stmt, 8, processedAttachment.filePath == nil ? processedAttachment.data : nil)
                bindText(stmt, 9, processedAttachment.contentId)
                sqlite3_bind_int(stmt, 10, processedAttachment.isInline ? 1 : 0)
                bindText(stmt, 11, processedAttachment.filePath)
                bindText(stmt, 12, processedAttachment.checksum)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to store attachment: \(processedAttachment.partId)")
                }
            }
        }
    }
    
    public func get(accountId: UUID, folder: String, uid: String, partId: String) throws -> AttachmentEntity? {
        return try DAOPerformanceMonitor.measure("get_attachment") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT part_id, filename, mime_type, size_bytes, data,
                           content_id, is_inline, file_path, checksum
                    FROM \(MailSchema.tAttachment) 
                    WHERE account_id = ? AND folder = ? AND uid = ? AND part_id = ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, folder)
                bindText(stmt, 3, uid)
                bindText(stmt, 4, partId)
                
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    return nil
                }
                
                return try buildAttachmentEntity(stmt: stmt, accountId: accountId, 
                                               folder: folder, uid: uid)
            }
        }
    }
    
    public func getAll(accountId: UUID, folder: String, uid: String) throws -> [AttachmentEntity] {
        return try DAOPerformanceMonitor.measure("get_all_attachments") {
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
                    let attachment = try buildAttachmentEntity(stmt: stmt, accountId: accountId,
                                                             folder: folder, uid: uid)
                    attachments.append(attachment)
                }
                
                return attachments
            }
        }
    }
    
    // MARK: - File Storage Migration
    
    public func migrateToFileStorage(attachment: AttachmentEntity) throws -> AttachmentEntity {
        guard let data = attachment.data else {
            return attachment // No data to migrate
        }
        
        let checksum = calculateChecksum(data: data)
        let fileName = "\(checksum)_\(attachment.filename)"
        let filePath = attachmentsDirectory.appendingPathComponent(fileName)
        
        // Check if file already exists (deduplication)
        if !FileManager.default.fileExists(atPath: filePath.path) {
            try data.write(to: filePath)
        }
        
        return AttachmentEntity(
            accountId: attachment.accountId,
            folder: attachment.folder,
            uid: attachment.uid,
            partId: attachment.partId,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            data: nil, // Remove from memory
            contentId: attachment.contentId,
            isInline: attachment.isInline,
            filePath: fileName, // Store relative path
            checksum: checksum
        )
    }
    
    public func getAttachmentData(attachment: AttachmentEntity) throws -> Data? {
        // Return inline data if available
        if let data = attachment.data {
            return data
        }
        
        // Load from file if file path is available
        if let fileName = attachment.filePath {
            let filePath = attachmentsDirectory.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: filePath.path) else {
                throw DAOError.notFound
            }
            return try Data(contentsOf: filePath)
        }
        
        return nil
    }
    
    // MARK: - Deduplication
    
    public func deduplicateAttachment(attachment: AttachmentEntity) throws -> AttachmentEntity {
        guard let data = attachment.data else {
            return attachment
        }
        
        let checksum = calculateChecksum(data: data)
        
        // Check if we already have this attachment by checksum
        let existingAttachment = try findAttachmentByChecksum(checksum)
        
        if let existing = existingAttachment {
            // Return existing attachment with updated metadata
            return AttachmentEntity(
                accountId: attachment.accountId,
                folder: attachment.folder,
                uid: attachment.uid,
                partId: attachment.partId,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
                data: existing.filePath == nil ? existing.data : nil,
                contentId: attachment.contentId,
                isInline: attachment.isInline,
                filePath: existing.filePath,
                checksum: checksum
            )
        }
        
        // Return original attachment with checksum
        return AttachmentEntity(
            accountId: attachment.accountId,
            folder: attachment.folder,
            uid: attachment.uid,
            partId: attachment.partId,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            sizeBytes: attachment.sizeBytes,
            data: attachment.data,
            contentId: attachment.contentId,
            isInline: attachment.isInline,
            filePath: attachment.filePath,
            checksum: checksum
        )
    }
    
    private func findAttachmentByChecksum(_ checksum: String) throws -> AttachmentEntity? {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT account_id, folder, uid, part_id, filename, mime_type, 
                       size_bytes, data, content_id, is_inline, file_path, checksum
                FROM \(MailSchema.tAttachment) 
                WHERE checksum = ?
                LIMIT 1
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindText(stmt, 1, checksum)
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            
            let accountId = stmt.columnUUID(0)!
            let folder = stmt.columnText(1) ?? ""
            let uid = stmt.columnText(2) ?? ""
            
            return try buildAttachmentEntity(stmt: stmt, accountId: accountId,
                                           folder: folder, uid: uid)
        }
    }
    
    // MARK: - Cleanup Operations
    
    public func cleanupOrphanedFiles() throws {
        try DAOPerformanceMonitor.measure("cleanup_orphaned_files") {
            // Get all file paths from database
            let dbFilePaths = try getAllFilePathsFromDB()
            
            // Get all files in attachments directory
            let diskFiles = try FileManager.default.contentsOfDirectory(at: attachmentsDirectory,
                                                                        includingPropertiesForKeys: nil)
            
            // Remove files not referenced in database
            for fileURL in diskFiles {
                let fileName = fileURL.lastPathComponent
                if !dbFilePaths.contains(fileName) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }
    
    private func getAllFilePathsFromDB() throws -> Set<String> {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = "SELECT DISTINCT file_path FROM \(MailSchema.tAttachment) WHERE file_path IS NOT NULL"
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            var filePaths = Set<String>()
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let filePath = stmt.columnText(0) {
                    filePaths.insert(filePath)
                }
            }
            
            return filePaths
        }
    }
    
    // MARK: - Storage Metrics
    
    public func getStorageMetrics() throws -> AttachmentStorageMetrics {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT 
                    COUNT(*) as total_count,
                    COUNT(CASE WHEN data IS NOT NULL THEN 1 END) as db_stored,
                    COUNT(CASE WHEN file_path IS NOT NULL THEN 1 END) as file_stored,
                    COALESCE(SUM(size_bytes), 0) as total_size,
                    COUNT(*) - COUNT(DISTINCT checksum) as duplicates
                FROM \(MailSchema.tAttachment)
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw DAOError.sqlError("Failed to get storage metrics")
            }
            
            return AttachmentStorageMetrics(
                totalAttachments: stmt.columnInt(0),
                dbStoredCount: stmt.columnInt(1),
                fileStoredCount: stmt.columnInt(2),
                totalSizeBytes: stmt.columnInt64(3),
                duplicateCount: stmt.columnInt(4)
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func buildAttachmentEntity(stmt: OpaquePointer, accountId: UUID, 
                                     folder: String, uid: String) throws -> AttachmentEntity {
        let partId = stmt.columnText(0) ?? ""
        let filename = stmt.columnText(1) ?? ""
        let mimeType = stmt.columnText(2) ?? ""
        let sizeBytes = stmt.columnInt(3)
        let data = stmt.columnBlob(4)
        let contentId = stmt.columnText(5)
        let isInline = sqlite3_column_int(stmt, 6) != 0
        let filePath = stmt.columnText(7)
        let checksum = stmt.columnText(8)
        
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
            filePath: filePath,
            checksum: checksum
        )
    }
    
    private func calculateChecksum(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
