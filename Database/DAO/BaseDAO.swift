// AILO_APP/Core/Storage/BaseDAO.swift
// Base DAO class with shared DB operations and SQLite connection management
// Phase 1: Foundation layer for all specialized DAOs

import Foundation
import SQLite3

public class BaseDAO {
    
    // MARK: - Properties
    
    internal var db: OpaquePointer?
    internal let dbPath: String
    internal let dbQueue: DispatchQueue
    
    // MARK: - Database Connection Sharing
    
    private var isUsingSharedConnection = false
    
    internal func setSharedConnection(_ sharedDB: OpaquePointer?) {
        // Close existing connection if we own it
        if let currentDB = db, !isUsingSharedConnection {
            sqlite3_close(currentDB)
        }
        
        db = sharedDB
        isUsingSharedConnection = (sharedDB != nil)
    }
    
    // MARK: - Initialization
    
    public init(dbPath: String) {
        self.dbPath = dbPath
        self.dbQueue = DispatchQueue(label: "com.ailo.dao.\(type(of: self))", qos: .userInitiated)
    }
    
    deinit {
        closeDatabase()
    }
    
    // MARK: - Database Connection Management
    
    public func openDatabase() throws {
        guard db == nil else { return }
        
        if isUsingSharedConnection {
            throw DAOError.databaseError("Cannot open individual connection when using shared connection")
        }
        
        let result = sqlite3_open_v2(dbPath, &db, 
                                   SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, 
                                   nil)
        
        guard result == SQLITE_OK else {
            throw DAOError.databaseError("Failed to open database: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        try configurePragmas()
    }
    
    public func closeDatabase() {
        if let db = db, !isUsingSharedConnection {
            sqlite3_close(db)
        }
        self.db = nil
        isUsingSharedConnection = false
    }
    
    public func closeDatabaseIfOwned() {
        // Only close if this DAO owns the connection (not shared)
        if let db = db, !isUsingSharedConnection {
            sqlite3_close(db) 
            self.db = nil
            isUsingSharedConnection = false
        }
    }
    
    private func configurePragmas() throws {
        let pragmas = [
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA cache_size = -2000;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA mmap_size = 268435456;",
            "PRAGMA foreign_keys = ON;"
        ]
        
        for pragma in pragmas {
            try execDirect(pragma)  // ← Use direct version since we're already in connection setup
        }
    }
    
    // MARK: - Core Database Operations
    
    // Internal version without queue sync for use within transactions
    private func execDirect(_ sql: String) throws {
        try ensureOpen()
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        
        if let errorMsg = errorMsg {
            let error = String(cString: errorMsg)
            sqlite3_free(errorMsg)
            throw DAOError.sqlError(error)
        }
        
        guard result == SQLITE_OK else {
            throw DAOError.databaseError("Exec failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    // Public version with queue synchronization
    public func exec(_ sql: String) throws {
        try dbQueue.sync {
            try execDirect(sql)
        }
    }
    
    public func prepare(_ sql: String) throws -> OpaquePointer {
        try ensureOpen()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        
        guard result == SQLITE_OK, let stmt = statement else {
            throw DAOError.sqlError("Prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        
        return stmt
    }
    
    public func finalize(_ statement: OpaquePointer) {
        sqlite3_finalize(statement)
    }
    
    // MARK: - Transaction Management
    
    public func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        return try dbQueue.sync {
            try ensureOpen()
            try execDirect("BEGIN TRANSACTION")  // ← No nested dbQueue.sync!
            
            do {
                let result = try operation()
                try execDirect("COMMIT")
                return result
            } catch {
                try? execDirect("ROLLBACK")
                throw error
            }
        }
    }
    
    // MARK: - Debug Helper Methods
    
    internal func debugBoundValues(_ statement: OpaquePointer) {
        let paramCount = sqlite3_bind_parameter_count(statement)
        print("🔍 [DEBUG-BOUND-VALUES] Parameter count: \(paramCount)")
        
        for i in 1...paramCount {
            let paramType = sqlite3_column_type(statement, i - 1)
            switch paramType {
            case SQLITE_INTEGER:
                let value = sqlite3_column_int64(statement, i - 1)
                print("   [\(i)] INTEGER: \(value)")
            case SQLITE_FLOAT:
                let value = sqlite3_column_double(statement, i - 1)
                print("   [\(i)] FLOAT: \(value)")
            case SQLITE_TEXT:
                if let cString = sqlite3_column_text(statement, i - 1) {
                    let value = String(cString: cString)
                    print("   [\(i)] TEXT: '\(value)'")
                } else {
                    print("   [\(i)] TEXT: NULL")
                }
            case SQLITE_BLOB:
                print("   [\(i)] BLOB: [binary data]")
            case SQLITE_NULL:
                print("   [\(i)] NULL")
            default:
                print("   [\(i)] UNKNOWN TYPE: \(paramType)")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    internal func ensureOpen() throws {
        if db == nil {
            if isUsingSharedConnection {
                throw DAOError.databaseError("Shared connection was lost")
            }
            try openDatabase()
        }
    }
    
    // Separate method for connection validation (call only when needed)
    internal func validateConnection() throws {
        guard let db = db else {
            throw DAOError.databaseError("No database connection")
        }
        
        let sql = "SELECT 1;"
        var statement: OpaquePointer?
        let testResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        if testResult == SQLITE_OK {
            sqlite3_finalize(statement)
        } else {
            throw DAOError.databaseError("Database connection is invalid: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    
    internal func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        print("🔍 [BIND-TEXT] Index: \(index), Value: '\(value ?? "NULL")' (count: \(value?.count ?? 0))")
        
        if let value = value {
            // CRITICAL FIX: Use SQLITE_TRANSIENT to force SQLite to copy the string
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            print("🔍 [BIND-TEXT] SQLite bind result: \(result) (SQLITE_OK = \(SQLITE_OK))")
        } else {
            sqlite3_bind_null(statement, index)
            print("🔍 [BIND-TEXT] Bound NULL value")
        }
    }
    
    internal func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value = value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    
    internal func bindInt64(_ statement: OpaquePointer, _ index: Int32, _ value: Int64?) {
        if let value = value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    
    internal func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    
    internal func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ data: Data?) {
        if let data = data {
            // CRITICAL FIX: Use SQLITE_TRANSIENT to force SQLite to copy the blob data
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
    
    internal func bindUUID(_ statement: OpaquePointer, _ index: Int32, _ uuid: UUID?) {
        let uuidString = uuid?.uuidString
        print("🔍 [BIND-UUID] Index: \(index), UUID: '\(uuidString ?? "NULL")' (count: \(uuidString?.count ?? 0))")
        bindText(statement, index, uuidString)
    }
    
    internal func bindDate(_ statement: OpaquePointer, _ index: Int32, _ date: Date?) {
        let timestamp = date?.timeIntervalSince1970
        print("🔍 [BIND-DATE] Index: \(index), Date: \(date?.description ?? "NULL"), Timestamp: \(timestamp ?? 0)")
        bindDouble(statement, index, timestamp)
    }
    
    internal func bindStringArray(_ statement: OpaquePointer, _ index: Int32, _ array: [String]) {
        let joined = array.joined(separator: ",")
        let finalValue = joined.isEmpty ? nil : joined
        print("🔍 [BIND-STRINGARRAY] Index: \(index), Array: \(array), Joined: '\(finalValue ?? \"NULL\")'")
        bindText(statement, index, finalValue)
    }

    internal func bindBool(_ statement: OpaquePointer, _ index: Int32, _ value: Bool) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    // Helper to create contextualized database errors
    internal func dbError(context: String) -> DAOError {
        let errorMsg = db != nil ? String(cString: sqlite3_errmsg(db)) : "No database connection"
        return DAOError.databaseError("\(context): \(errorMsg)")
    }
}

// MARK: - Error Types

public enum DAOError: Error, LocalizedError {
    case databaseError(String)
    case sqlError(String)
    case notFound
    case invalidData(String)
    
    public var errorDescription: String? {
        switch self {
        case .databaseError(let message):
            return "Database error: \(message)"
        case .sqlError(let message):
            return "SQL error: \(message)"
        case .notFound:
            return "Record not found"
        case .invalidData(let message):
            return "Invalid data: \(message)"
        }
    }
}
