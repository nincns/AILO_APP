// AILO_APP/Core/Storage/AccountDAO.swift
// Specialized account management with credentials and settings
// Phase 3: Account operations layer

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol AccountDAO {
    // Core account operations
    func store(_ account: AccountEntity) throws
    func get(_ accountId: UUID) throws -> AccountEntity?
    func getAll() throws -> [AccountEntity]
    func delete(_ accountId: UUID) throws
    
    // Account settings and configuration
    func updateDisplayName(_ accountId: UUID, displayName: String) throws
    func updateServerSettings(_ accountId: UUID, imapHost: String, smtpHost: String) throws
    func updateLastSeen(_ accountId: UUID) throws
    
    // Account validation and health
    func validateAccount(_ accountId: UUID) throws -> Bool
    func getAccountStats(_ accountId: UUID) throws -> AccountStats
}

// MARK: - Supporting Types

public struct AccountStats: Sendable {
    public let totalFolders: Int
    public let totalMessages: Int
    public let totalUnread: Int
    public let lastSyncDate: Date?
    public let storageSize: Int64
    
    public init(totalFolders: Int, totalMessages: Int, totalUnread: Int, 
                lastSyncDate: Date?, storageSize: Int64) {
        self.totalFolders = totalFolders
        self.totalMessages = totalMessages
        self.totalUnread = totalUnread
        self.lastSyncDate = lastSyncDate
        self.storageSize = storageSize
    }
}

// MARK: - Implementation

public class AccountDAOImpl: BaseDAO, AccountDAO {
    
    public override init(dbPath: String) {
        super.init(dbPath: dbPath)
    }
    
    // MARK: - Core Operations
    
    public func store(_ account: AccountEntity) throws {
        try DAOPerformanceMonitor.measure("store_account") {
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    INSERT OR REPLACE INTO \(MailSchema.tAccounts)
                    (id, display_name, email_address, host_imap, host_smtp, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, account.id)
                bindText(stmt, 2, account.displayName)
                bindText(stmt, 3, account.emailAddress)
                bindText(stmt, 4, account.hostIMAP)
                bindText(stmt, 5, account.hostSMTP)
                bindDate(stmt, 6, account.createdAt)
                bindDate(stmt, 7, account.updatedAt)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to store account: \(account.id)")
                }
            }
        }
    }
    
    public func get(_ accountId: UUID) throws -> AccountEntity? {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT id, display_name, email_address, host_imap, host_smtp, created_at, updated_at
                FROM \(MailSchema.tAccounts)
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            
            return buildAccountEntity(from: stmt)
        }
    }
    
    public func getAll() throws -> [AccountEntity] {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT id, display_name, email_address, host_imap, host_smtp, created_at, updated_at
                FROM \(MailSchema.tAccounts)
                ORDER BY display_name
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            var accounts: [AccountEntity] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                accounts.append(buildAccountEntity(from: stmt))
            }
            
            return accounts
        }
    }
    
    public func delete(_ accountId: UUID) throws {
        try DAOPerformanceMonitor.measure("delete_account") {
            try withTransaction {
                    try ensureOpen()
                    
                    // Delete related data first (cascade delete)
                    let deleteAttachments = "DELETE FROM \(MailSchema.tAttachment) WHERE account_id = ?"
                    let deleteBody = "DELETE FROM \(MailSchema.tMsgBody) WHERE account_id = ?"
                    let deleteHeaders = "DELETE FROM \(MailSchema.tMsgHeader) WHERE account_id = ?"
                    let deleteOutbox = "DELETE FROM \(MailSchema.tOutbox) WHERE account_id = ?"
                    let deleteFolders = "DELETE FROM \(MailSchema.tFolders) WHERE account_id = ?"
                    let deleteAccount = "DELETE FROM \(MailSchema.tAccounts) WHERE id = ?"
                    
                    for sql in [deleteAttachments, deleteBody, deleteHeaders, deleteOutbox, deleteFolders, deleteAccount] {
                        let stmt = try prepare(sql)
                        defer { finalize(stmt) }
                        
                        bindUUID(stmt, 1, accountId)
                        
                        guard sqlite3_step(stmt) == SQLITE_DONE else {
                            throw DAOError.sqlError("Failed to delete account data: \(accountId)")
                        }
                    }
                }
            }
        }
    
    // MARK: - Settings and Configuration
    
    public func updateDisplayName(_ accountId: UUID, displayName: String) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tAccounts)
                SET display_name = ?, updated_at = ?
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindText(stmt, 1, displayName)
            bindDate(stmt, 2, Date())
            bindUUID(stmt, 3, accountId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update display name for account: \(accountId)")
            }
        }
    }
    
    public func updateServerSettings(_ accountId: UUID, imapHost: String, smtpHost: String) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tAccounts)
                SET host_imap = ?, host_smtp = ?, updated_at = ?
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindText(stmt, 1, imapHost)
            bindText(stmt, 2, smtpHost)
            bindDate(stmt, 3, Date())
            bindUUID(stmt, 4, accountId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update server settings for account: \(accountId)")
            }
        }
    }
    
    public func updateLastSeen(_ accountId: UUID) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tAccounts)
                SET updated_at = ?
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindDate(stmt, 1, Date())
            bindUUID(stmt, 2, accountId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update last seen for account: \(accountId)")
            }
        }
    }
    
    // MARK: - Validation and Health
    
    public func validateAccount(_ accountId: UUID) throws -> Bool {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT COUNT(*) FROM \(MailSchema.tAccounts)
                WHERE id = ? AND email_address IS NOT NULL 
                AND host_imap IS NOT NULL AND host_smtp IS NOT NULL
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return false
            }
            
            return stmt.columnInt(0) > 0
        }
    }
    
    public func getAccountStats(_ accountId: UUID) throws -> AccountStats {
        return try DAOPerformanceMonitor.measure("get_account_stats") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT 
                        (SELECT COUNT(*) FROM \(MailSchema.tFolders) WHERE account_id = ?) as folder_count,
                        (SELECT COUNT(*) FROM \(MailSchema.tMsgHeader) WHERE account_id = ?) as message_count,
                        (SELECT COUNT(*) FROM \(MailSchema.tMsgHeader) WHERE account_id = ? AND flags NOT LIKE '%\\Seen%') as unread_count,
                        (SELECT MAX(updated_at) FROM \(MailSchema.tAccounts) WHERE id = ?) as last_sync,
                        (SELECT COALESCE(SUM(raw_size), 0) FROM \(MailSchema.tMsgBody) WHERE account_id = ?) as storage_size
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindUUID(stmt, 2, accountId)
                bindUUID(stmt, 3, accountId)
                bindUUID(stmt, 4, accountId)
                bindUUID(stmt, 5, accountId)
                
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    throw DAOError.sqlError("Failed to get account stats")
                }
                
                let totalFolders = stmt.columnInt(0)
                let totalMessages = stmt.columnInt(1)
                let totalUnread = stmt.columnInt(2)
                let lastSyncDate = stmt.columnDate(3)
                let storageSize = stmt.columnInt64(4)
                
                return AccountStats(
                    totalFolders: totalFolders,
                    totalMessages: totalMessages,
                    totalUnread: totalUnread,
                    lastSyncDate: lastSyncDate,
                    storageSize: storageSize
                )
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func buildAccountEntity(from stmt: OpaquePointer) -> AccountEntity {
        let id = stmt.columnUUID(0)!
        let displayName = stmt.columnText(1) ?? ""
        let emailAddress = stmt.columnText(2) ?? ""
        let hostIMAP = stmt.columnText(3) ?? ""
        let hostSMTP = stmt.columnText(4) ?? ""
        let createdAt = stmt.columnDate(5) ?? Date()
        let updatedAt = stmt.columnDate(6) ?? Date()
        
        return AccountEntity(
            id: id,
            displayName: displayName,
            emailAddress: emailAddress,
            hostIMAP: hostIMAP,
            hostSMTP: hostSMTP,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
