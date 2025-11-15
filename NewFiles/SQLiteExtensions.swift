// SQLiteExtensions.swift
// Fehlende Extension-Methoden für SQLite-Operationen

import Foundation
import SQLite3

// MARK: - SQLite Statement Extensions

extension OpaquePointer {
    
    // MARK: - Column Reading Methods
    
    func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(self, index) else { return nil }
        return String(cString: cString)
    }
    
    func columnInt(_ index: Int32) -> Int {
        return Int(sqlite3_column_int64(self, index))
    }
    
    func columnInt64(_ index: Int32) -> Int64 {
        return sqlite3_column_int64(self, index)
    }
    
    func columnDouble(_ index: Int32) -> Double {
        return sqlite3_column_double(self, index)
    }
    
    func columnBool(_ index: Int32) -> Bool {
        return sqlite3_column_int(self, index) != 0
    }
    
    func columnBlob(_ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(self, index) else { return nil }
        let length = sqlite3_column_bytes(self, index)
        return Data(bytes: bytes, count: Int(length))
    }
    
    func columnUUID(_ index: Int32) -> UUID? {
        guard let text = columnText(index) else { return nil }
        return UUID(uuidString: text)
    }
    
    func columnDate(_ index: Int32) -> Date? {
        let timestamp = columnInt64(index)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(timestamp))
    }
}

// MARK: - BaseDAO Extensions for Binding

extension BaseDAO {
    
    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, index, Int64(value))
    }
    
    func bindInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }
    
    func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }
    
    func bindBool(_ stmt: OpaquePointer?, _ index: Int32, _ value: Bool) {
        sqlite3_bind_int(stmt, index, value ? 1 : 0)
    }
    
    func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ data: Data?) {
        if let data = data {
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    func bindUUID(_ stmt: OpaquePointer?, _ index: Int32, _ uuid: UUID?) {
        if let uuid = uuid {
            bindText(stmt, index, uuid.uuidString)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    func bindDate(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date = date {
            bindInt64(stmt, index, Int64(date.timeIntervalSince1970))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

// MARK: - MailWriteDAO Missing Methods

extension MailWriteDAO {
    
    func incrementBlobReference(blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE blob_meta 
            SET reference_count = reference_count + 1
            WHERE blob_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "incrementBlobReference")
        }
    }
    
    func decrementBlobReference(blobId: String) throws {
        try ensureOpen()
        
        let sql = """
            UPDATE blob_meta 
            SET reference_count = reference_count - 1
            WHERE blob_id = ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "decrementBlobReference")
        }
    }
    
    func deleteBlobMeta(blobId: String) throws {
        try ensureOpen()
        
        let sql = "DELETE FROM blob_meta WHERE blob_id = ?"
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindText(stmt, 1, blobId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "deleteBlobMeta")
        }
    }
}

// MARK: - MailReadDAO Missing Methods

extension MailReadDAO {
    
    func getBlobStorageMetrics() throws -> (totalBlobs: Int, totalSize: Int64, deduplicatedCount: Int, averageSize: Int) {
        try ensureOpen()
        
        let sql = """
            SELECT 
                COUNT(*) as total_blobs,
                SUM(size_bytes) as total_size,
                SUM(CASE WHEN reference_count > 1 THEN reference_count - 1 ELSE 0 END) as dedup_count,
                AVG(size_bytes) as avg_size
            FROM blob_meta
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return (0, 0, 0, 0)
        }
        
        return (
            totalBlobs: stmt.columnInt(0),
            totalSize: stmt.columnInt64(1),
            deduplicatedCount: stmt.columnInt(2),
            averageSize: stmt.columnInt(3)
        )
    }
    
    func getOrphanedBlobs() throws -> [String] {
        try ensureOpen()
        
        let sql = """
            SELECT blob_id FROM blob_meta 
            WHERE reference_count = 0
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        var orphaned: [String] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blobId = stmt.columnText(0) {
                orphaned.append(blobId)
            }
        }
        
        return orphaned
    }
    
    func getBlobsOlderThan(date: Date) throws -> [String] {
        try ensureOpen()
        
        let sql = """
            SELECT blob_id FROM blob_meta 
            WHERE last_accessed < ? OR last_accessed IS NULL
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        bindDate(stmt, 1, date)
        
        var old: [String] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blobId = stmt.columnText(0) {
                old.append(blobId)
            }
        }
        
        return old
    }
    
    func getAllBlobIds() throws -> [String] {
        try ensureOpen()
        
        let sql = "SELECT blob_id FROM blob_meta"
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        var ids: [String] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let blobId = stmt.columnText(0) {
                ids.append(blobId)
            }
        }
        
        return ids
    }
}
