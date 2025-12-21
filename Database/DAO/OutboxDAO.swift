// AILO_APP/Core/Storage/OutboxDAO.swift
// Specialized outbox management with queue operations and retry logic
// Phase 3: Outbox operations layer

import Foundation
import SQLite3

// MARK: - Protocol Definition

public protocol MailOutboxDAO {
    // Core operations
    func enqueue(_ item: OutboxItemEntity) throws
    func dequeue(for accountId: UUID) throws -> OutboxItemEntity?
    func updateStatus(_ itemId: UUID, status: OutboxStatusEntity, error: String?) throws
    func incrementAttempts(_ itemId: UUID) throws
    
    // Queue management
    func getPendingItems(for accountId: UUID, limit: Int) throws -> [OutboxItemEntity]
    func getFailedItems(for accountId: UUID) throws -> [OutboxItemEntity]
    func retryFailedItems(for accountId: UUID, maxAttempts: Int) throws
    
    // Cleanup operations
    func removeSentItems(olderThan: Date) throws
    func removeFailedItems(maxAge: TimeInterval) throws
    func cancelPendingItems(for accountId: UUID) throws
}

// MARK: - Implementation

public class MailOutboxDAOImpl: BaseDAO, MailOutboxDAO {
    
    private let maxRetryAttempts: Int
    
    public init(dbPath: String, maxRetryAttempts: Int = 3) {
        self.maxRetryAttempts = maxRetryAttempts
        super.init(dbPath: dbPath)
    }
    
    // MARK: - Core Operations
    
    public func enqueue(_ item: OutboxItemEntity) throws {
        try DAOPerformanceMonitor.measure("enqueue_outbox_item") {
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    INSERT OR REPLACE INTO \(MailSchema.tOutbox)
                    (id, account_id, created_at, last_attempt_at, attempts, status,
                     last_error, from_addr, to_addr, cc_addr, bcc_addr, subject,
                     text_body, html_body, attachments_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """

                let stmt = try prepare(sql)
                defer { finalize(stmt) }

                bindUUID(stmt, 1, item.id)
                bindUUID(stmt, 2, item.accountId)
                bindDate(stmt, 3, item.createdAt)
                bindDate(stmt, 4, item.lastAttemptAt)
                bindInt(stmt, 5, item.attempts)
                bindText(stmt, 6, item.status.rawValue)
                bindText(stmt, 7, item.lastError)
                bindText(stmt, 8, item.from)
                bindText(stmt, 9, item.to)
                bindText(stmt, 10, item.cc)
                bindText(stmt, 11, item.bcc)
                bindText(stmt, 12, item.subject)
                bindText(stmt, 13, item.textBody)
                bindText(stmt, 14, item.htmlBody)
                bindText(stmt, 15, item.attachmentsJson)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to enqueue outbox item: \(item.id)")
                }
            }
        }
    }
    
    public func dequeue(for accountId: UUID) throws -> OutboxItemEntity? {
        return try DAOPerformanceMonitor.measure("dequeue_outbox_item") {
            return try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    SELECT id, account_id, created_at, last_attempt_at, attempts, status,
                           last_error, from_addr, to_addr, cc_addr, bcc_addr, subject,
                           text_body, html_body, attachments_json
                    FROM \(MailSchema.tOutbox)
                    WHERE account_id = ? AND status = ?
                    ORDER BY created_at ASC
                    LIMIT 1
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindUUID(stmt, 1, accountId)
                bindText(stmt, 2, OutboxStatusEntity.pending.rawValue)
                
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    return nil
                }
                
                return buildOutboxItem(from: stmt)
            }
        }
    }
    
    public func updateStatus(_ itemId: UUID, status: OutboxStatusEntity, error: String?) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tOutbox)
                SET status = ?, last_error = ?, last_attempt_at = ?
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindText(stmt, 1, status.rawValue)
            bindText(stmt, 2, error)
            bindDate(stmt, 3, Date())
            bindUUID(stmt, 4, itemId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to update outbox item status: \(itemId)")
            }
        }
    }
    
    public func incrementAttempts(_ itemId: UUID) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tOutbox)
                SET attempts = attempts + 1, last_attempt_at = ?
                WHERE id = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindDate(stmt, 1, Date())
            bindUUID(stmt, 2, itemId)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to increment attempts for outbox item: \(itemId)")
            }
        }
    }
    
    // MARK: - Queue Management
    
    public func getPendingItems(for accountId: UUID, limit: Int) throws -> [OutboxItemEntity] {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT id, account_id, created_at, last_attempt_at, attempts, status,
                       last_error, from_addr, to_addr, cc_addr, bcc_addr, subject,
                       text_body, html_body, attachments_json
                FROM \(MailSchema.tOutbox)
                WHERE account_id = ? AND status = ?
                ORDER BY created_at ASC
                LIMIT ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, OutboxStatusEntity.pending.rawValue)
            bindInt(stmt, 3, limit)
            
            var items: [OutboxItemEntity] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(buildOutboxItem(from: stmt))
            }
            
            return items
        }
    }
    
    public func getFailedItems(for accountId: UUID) throws -> [OutboxItemEntity] {
        return try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                SELECT id, account_id, created_at, last_attempt_at, attempts, status,
                       last_error, from_addr, to_addr, cc_addr, bcc_addr, subject,
                       text_body, html_body, attachments_json
                FROM \(MailSchema.tOutbox)
                WHERE account_id = ? AND status = ?
                ORDER BY created_at DESC
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindUUID(stmt, 1, accountId)
            bindText(stmt, 2, OutboxStatusEntity.failed.rawValue)
            
            var items: [OutboxItemEntity] = []
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(buildOutboxItem(from: stmt))
            }
            
            return items
        }
    }
    
    public func retryFailedItems(for accountId: UUID, maxAttempts: Int) throws {
        try DAOPerformanceMonitor.measure("retry_failed_items") {
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    UPDATE \(MailSchema.tOutbox)
                    SET status = ?, last_error = NULL
                    WHERE account_id = ? AND status = ? AND attempts < ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindText(stmt, 1, OutboxStatusEntity.pending.rawValue)
                bindUUID(stmt, 2, accountId)
                bindText(stmt, 3, OutboxStatusEntity.failed.rawValue)
                bindInt(stmt, 4, maxAttempts)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to retry failed items")
                }
            }
        }
    }
    
    // MARK: - Cleanup Operations
    
    public func removeSentItems(olderThan: Date) throws {
        try DAOPerformanceMonitor.measure("remove_sent_items") {
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    DELETE FROM \(MailSchema.tOutbox)
                    WHERE status = ? AND created_at < ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindText(stmt, 1, OutboxStatusEntity.sent.rawValue)
                bindDate(stmt, 2, olderThan)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to remove sent items")
                }
            }
        }
    }
    
    public func removeFailedItems(maxAge: TimeInterval) throws {
        try DAOPerformanceMonitor.measure("remove_failed_items") {
            let cutoffDate = Date().addingTimeInterval(-maxAge)
            
            try dbQueue.sync {
                try ensureOpen()
                
                let sql = """
                    DELETE FROM \(MailSchema.tOutbox)
                    WHERE status = ? AND created_at < ?
                """
                
                let stmt = try prepare(sql)
                defer { finalize(stmt) }
                
                bindText(stmt, 1, OutboxStatusEntity.failed.rawValue)
                bindDate(stmt, 2, cutoffDate)
                
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw DAOError.sqlError("Failed to remove old failed items")
                }
            }
        }
    }
    
    public func cancelPendingItems(for accountId: UUID) throws {
        try dbQueue.sync {
            try ensureOpen()
            
            let sql = """
                UPDATE \(MailSchema.tOutbox)
                SET status = ?
                WHERE account_id = ? AND status = ?
            """
            
            let stmt = try prepare(sql)
            defer { finalize(stmt) }
            
            bindText(stmt, 1, OutboxStatusEntity.cancelled.rawValue)
            bindUUID(stmt, 2, accountId)
            bindText(stmt, 3, OutboxStatusEntity.pending.rawValue)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DAOError.sqlError("Failed to cancel pending items")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func buildOutboxItem(from stmt: OpaquePointer) -> OutboxItemEntity {
        let id = stmt.columnUUID(0)!
        let accountId = stmt.columnUUID(1)!
        let createdAt = stmt.columnDate(2)!
        let lastAttemptAt = stmt.columnDate(3)
        let attempts = stmt.columnInt(4)
        let statusString = stmt.columnText(5) ?? ""
        let status = OutboxStatusEntity(rawValue: statusString) ?? .pending
        let lastError = stmt.columnText(6)
        let from = stmt.columnText(7) ?? ""
        let to = stmt.columnText(8) ?? ""
        let cc = stmt.columnText(9) ?? ""
        let bcc = stmt.columnText(10) ?? ""
        let subject = stmt.columnText(11) ?? ""
        let textBody = stmt.columnText(12)
        let htmlBody = stmt.columnText(13)
        let attachmentsJson = stmt.columnText(14)

        return OutboxItemEntity(
            id: id,
            accountId: accountId,
            createdAt: createdAt,
            lastAttemptAt: lastAttemptAt,
            attempts: attempts,
            status: status,
            lastError: lastError,
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachmentsJson: attachmentsJson
        )
    }
}
