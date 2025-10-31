// AILO_APP/Core/Storage/FolderDAO.swift
// Specialized folder management with hierarchy and special folder mapping
// Phase 3: Folder operations layer

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol FolderDAO {
    // Core folder operations
    func store(_ folder: FolderEntity) throws
    func get(accountId: UUID, name: String) throws -> FolderEntity?
    func getAll(for accountId: UUID) throws -> [FolderEntity]
    
    // Special folder management
    func getSpecialFolders(for accountId: UUID) throws -> [String: String]
    func updateSpecialFolders(for accountId: UUID, mapping: [String: String]) throws
    
    // Folder hierarchy
    func getFolderHierarchy(for accountId: UUID) throws -> [FolderHierarchyNode]
    func updateFolderAttributes(accountId: UUID, name: String, attributes: [String]) throws
    
    // Cleanup operations
    func removeFoldersNotIn(accountId: UUID, folderNames: [String]) throws
    func getFolderStats(for accountId: UUID) throws -> [FolderStats]
}

// MARK: - Supporting Types

public struct FolderHierarchyNode: Sendable {
    public let folder: FolderEntity
    public let children: [FolderHierarchyNode]
    
    public init(folder: FolderEntity, children: [FolderHierarchyNode] = []) {
        self.folder = folder
        self.children = children
    }
}

public struct FolderStats: Sendable {
    public let folderName: String
    public let messageCount: Int
    public let unreadCount: Int
    public let totalSizeBytes: Int64
    
    public init(folderName: String, messageCount: Int, unreadCount: Int, totalSizeBytes: Int64) {
        self.folderName = folderName
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.totalSizeBytes = totalSizeBytes
    }
}

// MARK: - Implementation

public class FolderDAOImpl: BaseDAO, FolderDAO {
    
    public override init(dbPath: String) {
        super.init(dbPath: dbPath)
    }
    
    // MARK: - Core Operations
    
    public func store(_ folder: FolderEntity) throws {
        try DAOPerformanceMonitor.measure("store_folder") {
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    INSERT OR REPLACE INTO \(MailSchema.tFolders)
                    (account_id, name, special_use, delimiter, attributes)
                    VALUES (?, ?, ?, ?, ?)
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, folder.accountId)
                bindText(stmt, 2, folder.name)
                bindText(stmt, 3, folder.specialUse)
                bindText(stmt, 4, folder.delimiter)
                bindStringArray(stmt, 5, folder.attributes)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to store folder: \(folder.name)")
                }
            }
        }
    }
    
    public func get(accountId: UUID, name: String) throws -> FolderEntity? {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT account_id, name, special_use, delimiter, attributes
                FROM \(MailSchema.tFolders)
                WHERE account_id = ? AND name = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, name)
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            
            return buildFolderEntity(from: stmt)
        }
    }
    
    public func getAll(for accountId: UUID) throws -> [FolderEntity] {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT account_id, name, special_use, delimiter, attributes
                FROM \(MailSchema.tFolders)
                WHERE account_id = ?
                ORDER BY name
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            
            var folders: [FolderEntity] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                folders.append(buildFolderEntity(from: stmt))
            }
            
            return folders
        }
    }
    
    // MARK: - Special Folder Management
    
    public func getSpecialFolders(for accountId: UUID) throws -> [String: String] {
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
            
            var specialFolders: [String: String] = [:]
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = stmt.columnText(0),
                   let specialUse = stmt.columnText(1) {
                    specialFolders[specialUse] = name
                }
            }
            
            return specialFolders
        }
    }
    
    public func updateSpecialFolders(for accountId: UUID, mapping: [String: String]) throws {
        try DAOPerformanceMonitor.measure("update_special_folders") {
            try withTransaction {
                    try ensureOpen()
                    
                    // Clear existing special folder mappings
                    let clearSql = """
                        UPDATE \(MailSchema.tFolders)
                        SET special_use = NULL
                        WHERE account_id = ?
                    """
                    
                    let clearStmt = try prepare(clearSql)
                    defer { finalize(clearStmt) }
                    
                    bindUUID(clearStmt, 1, accountId)
                    guard sqlite3_step(clearStmt) == SQLITE_DONE else {
                        throw DAOError.sqlError("Failed to clear special folder mappings")
                    }
                    
                    // Update folders with new special use mappings
                    let updateSql = """
                        UPDATE \(MailSchema.tFolders)
                        SET special_use = ?
                        WHERE account_id = ? AND name = ?
                    """
                    
                    let updateStmt = try prepare(updateSql)
                    defer { finalize(updateStmt) }
                    
                    for (specialUse, folderName) in mapping {
                        sqlite3_reset(updateStmt)
                        
                        bindText(updateStmt, 1, specialUse)
                        bindUUID(updateStmt, 2, accountId)
                        bindText(updateStmt, 3, folderName)
                        
                        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                            throw DAOError.sqlError("Failed to update special folder: \(folderName)")
                        }
                    }
                }
            }
        }
    
    // MARK: - Folder Hierarchy
    
    public func getFolderHierarchy(for accountId: UUID) throws -> [FolderHierarchyNode] {
        let folders = try getAll(for: accountId)
        return buildHierarchy(from: folders)
    }
    
    private func buildHierarchy(from folders: [FolderEntity]) -> [FolderHierarchyNode] {
        var folderMap: [String: FolderEntity] = [:]
        var childrenMap: [String: [FolderEntity]] = [:]
        
        // Build maps for efficient hierarchy construction
        for folder in folders {
            folderMap[folder.name] = folder
            let delimiter = folder.delimiter ?? "/"
            
            // Find parent folder name
            if let lastDelimiterIndex = folder.name.lastIndex(of: Character(delimiter)) {
                let parentName = String(folder.name[..<lastDelimiterIndex])
                childrenMap[parentName, default: []].append(folder)
            } else {
                // Root level folder
                childrenMap["", default: []].append(folder)
            }
        }
        
        // Build hierarchy starting from root level
        return buildNodeChildren(parentName: "", childrenMap: childrenMap, folderMap: folderMap)
    }
    
    private func buildNodeChildren(parentName: String, childrenMap: [String: [FolderEntity]], 
                                 folderMap: [String: FolderEntity]) -> [FolderHierarchyNode] {
        guard let children = childrenMap[parentName] else { return [] }
        
        return children.map { folder in
            let childNodes = buildNodeChildren(parentName: folder.name, 
                                             childrenMap: childrenMap, 
                                             folderMap: folderMap)
            return FolderHierarchyNode(folder: folder, children: childNodes)
        }.sorted { $0.folder.name < $1.folder.name }
    }
    
    public func updateFolderAttributes(accountId: UUID, name: String, attributes: [String]) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tFolders)
                SET attributes = ?
                WHERE account_id = ? AND name = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindStringArray(stmt, 1, attributes)
            bindUUID(stmt, 2, accountId)
            bindText(stmt, 3, name)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update folder attributes: \(name)")
            }
        }
    }
    
    // MARK: - Cleanup Operations
    
    public func removeFoldersNotIn(accountId: UUID, folderNames: [String]) throws {
        try DAOPerformanceMonitor.measure("cleanup_folders") {
            try dbQueue.sync {
                try ensureOpen()
                
                guard !folderNames.isEmpty else {
                    // Remove all folders for this account
                    let sql = "DELETE FROM \(MailSchema.tFolders) WHERE account_id = ?"
                    let stmt = try prepare(sql)
                    defer { finalize(stmt) }
                    
                    bindUUID(stmt, 1, accountId)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw DAOError.sqlError("Failed to remove all folders")
                    }
                    return
                }
                
                // Create placeholders for IN clause
                let placeholders = Array(repeating: "?", count: folderNames.count).joined(separator: ", ")
                let sql = """
                    DELETE FROM \(MailSchema.tFolders)
                    WHERE account_id = ? AND name NOT IN (\(placeholders))
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                
                for (index, folderName) in folderNames.enumerated() {
                    bindText(stmt, Int32(index + 2), folderName)
                }
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to cleanup obsolete folders")
                }
            }
        }
    }
    
    // MARK: - Folder Statistics
    
    public func getFolderStats(for accountId: UUID) throws -> [FolderStats] {
        return try DAOPerformanceMonitor.measure("get_folder_stats") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT 
                        h.folder,
                        COUNT(h.uid) as message_count,
                        COUNT(CASE WHEN h.flags NOT LIKE '%\\Seen%' THEN 1 END) as unread_count,
                        COALESCE(SUM(b.raw_size), 0) as total_size
                    FROM \(MailSchema.tMsgHeader) h
                    LEFT JOIN \(MailSchema.tMsgBody) b ON h.account_id = b.account_id 
                        AND h.folder = b.folder AND h.uid = b.uid
                    WHERE h.account_id = ?
                    GROUP BY h.folder
                    ORDER BY h.folder
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                
                var stats: [FolderStats] = []
                
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let folderName = stmt.columnText(0) ?? ""
                    let messageCount = stmt.columnInt(1)
                    let unreadCount = stmt.columnInt(2)
                    let totalSize = stmt.columnInt64(3)
                    
                    stats.append(FolderStats(
                        folderName: folderName,
                        messageCount: messageCount,
                        unreadCount: unreadCount,
                        totalSizeBytes: totalSize
                    ))
                }
                
                return stats
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func buildFolderEntity(from stmt: OpaquePointer) -> FolderEntity {
        let accountId = stmt.columnUUID(0)!
        let name = stmt.columnText(1) ?? ""
        let specialUse = stmt.columnText(2)
        let delimiter = stmt.columnText(3)
        let attributes = stmt.columnStringArray(4)
        
        return FolderEntity(
            accountId: accountId,
            name: name,
            specialUse: specialUse,
            delimiter: delimiter,
            attributes: attributes
        )
    }
}
