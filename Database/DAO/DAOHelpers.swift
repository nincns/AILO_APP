// AILO_APP/Core/Storage/DAOHelpers.swift
// Helper functions and utilities for DAO operations
// Phase 1: Foundation layer utilities

import Foundation
import SQLite3

// MARK: - SQLite Type Extraction Helpers

public extension OpaquePointer {
    func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(self, index) else { return nil }
        return String(cString: cString)
    }
    
    func columnInt(_ index: Int32) -> Int {
        return Int(sqlite3_column_int(self, index))
    }
    
    func columnInt64(_ index: Int32) -> Int64 {
        return sqlite3_column_int64(self, index)
    }
    
    func columnDouble(_ index: Int32) -> Double {
        return sqlite3_column_double(self, index)
    }
    
    func columnBlob(_ index: Int32) -> Data? {
        guard let blob = sqlite3_column_blob(self, index) else { return nil }
        let bytes = sqlite3_column_bytes(self, index)
        return Data(bytes: blob, count: Int(bytes))
    }
    
    func columnUUID(_ index: Int32) -> UUID? {
        guard let uuidString = columnText(index) else { return nil }
        return UUID(uuidString: uuidString)
    }
    
    func columnDate(_ index: Int32) -> Date? {
        let timestamp = columnDouble(index)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    func columnStringArray(_ index: Int32) -> [String] {
        guard let text = columnText(index), !text.isEmpty else { return [] }
        return text.split(separator: ",").map(String.init)
    }
    
    func columnIsNull(_ index: Int32) -> Bool {
        return sqlite3_column_type(self, index) == SQLITE_NULL
    }
}

// MARK: - Performance Monitoring

public class DAOPerformanceMonitor {
    private static let shared = DAOPerformanceMonitor()
    private var metrics: [String: DAOMetric] = [:]
    private let queue = DispatchQueue(label: "com.ailo.dao.metrics")
    
    private struct DAOMetric {
        var totalTime: TimeInterval = 0
        var callCount: Int = 0
        var averageTime: TimeInterval { totalTime / Double(callCount) }
    }
    
    public static func measure<T>(_ operation: String, _ block: () throws -> T) rethrows -> T {
        let startTime = Date().timeIntervalSince1970
        let result = try block()
        let duration = Date().timeIntervalSince1970 - startTime
        
        shared.queue.async {
            shared.recordMetric(operation, duration: duration)
        }
        
        return result
    }
    
    private func recordMetric(_ operation: String, duration: TimeInterval) {
        if var metric = metrics[operation] {
            metric.totalTime += duration
            metric.callCount += 1
            metrics[operation] = metric
        } else {
            metrics[operation] = DAOMetric(totalTime: duration, callCount: 1)
        }
    }
    
    public static func getMetrics() -> [String: (average: TimeInterval, calls: Int)] {
        return shared.queue.sync {
            return shared.metrics.mapValues { (average: $0.averageTime, calls: $0.callCount) }
        }
    }
    
    public static func resetMetrics() {
        shared.queue.sync {
            shared.metrics.removeAll()
        }
    }
}

// MARK: - Transaction Utilities

public class DAOTransactionManager {
    private let baseDAO: BaseDAO
    
    public init(_ baseDAO: BaseDAO) {
        self.baseDAO = baseDAO
    }
    
    public func performBatch<T>(_ operations: [() throws -> T]) throws -> [T] {
        return try baseDAO.withTransaction {
            var results: [T] = []
            for operation in operations {
                results.append(try operation())
            }
            return results
        }
    }
    
    public func performBatchInsert<Entity>(_ entities: [Entity], 
                                         batchSize: Int = 100,
                                         insertOperation: ([Entity]) throws -> Void) throws {
        guard !entities.isEmpty else { return }
        
        let batches = entities.chunked(into: batchSize)
        for batch in batches {
            try baseDAO.withTransaction {
                try insertOperation(batch)
            }
        }
    }
}

// MARK: - Array Extension for Chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - SQL Query Builder Helpers

public struct SQLQueryBuilder {
    
    public static func select(_ columns: String...) -> SelectBuilder {
        return SelectBuilder(columns: columns.joined(separator: ", "))
    }
    
    public struct SelectBuilder {
        private let columns: String
        
        init(columns: String) {
            self.columns = columns
        }
        
        public func from(_ table: String) -> FromBuilder {
            return FromBuilder(query: "SELECT \(columns) FROM \(table)")
        }
    }
    
    public struct FromBuilder {
        private let query: String
        
        init(query: String) {
            self.query = query
        }
        
        public func whereCondition(_ condition: String) -> WhereBuilder {
            return WhereBuilder(query: query + " WHERE \(condition)")
        }
        
        public func orderBy(_ column: String, ascending: Bool = true) -> OrderBuilder {
            return OrderBuilder(query: query + " ORDER BY \(column) \(ascending ? "ASC" : "DESC")")
        }
        
        public func build() -> String {
            return query
        }
    }
    
    public struct WhereBuilder {
        private let query: String
        
        init(query: String) {
            self.query = query
        }
        
        public func orderBy(_ column: String, ascending: Bool = true) -> OrderBuilder {
            return OrderBuilder(query: query + " ORDER BY \(column) \(ascending ? "ASC" : "DESC")")
        }
        
        public func build() -> String {
            return query
        }
    }
    
    public struct OrderBuilder {
        private let query: String
        
        init(query: String) {
            self.query = query
        }
        
        public func limit(_ count: Int, offset: Int = 0) -> String {
            if offset > 0 {
                return query + " LIMIT \(count) OFFSET \(offset)"
            } else {
                return query + " LIMIT \(count)"
            }
        }
        
        public func build() -> String {
            return query
        }
    }
}

// MARK: - Schema Validation Helpers

public struct DAOSchemaValidator {
    private let baseDAO: BaseDAO
    
    public init(_ baseDAO: BaseDAO) {
        self.baseDAO = baseDAO
    }
    
    public func validateTable(_ tableName: String) throws -> Bool {
        // First, ensure any pending transactions are committed
        try baseDAO.exec("PRAGMA schema_version")
        
        // Use PRAGMA table_info which is more reliable than sqlite_master
        let sql = "PRAGMA table_info(\(tableName))"
        let stmt = try baseDAO.prepare(sql)
        defer { baseDAO.finalize(stmt) }
        
        // If table exists, PRAGMA table_info will return at least one row
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        
        // Debug log for troubleshooting - but only if table not found
        if !exists {
            print("🔍 DEBUG: Table '\(tableName)' not found via PRAGMA table_info")
            
            // Fallback: Try sqlite_master as secondary check
            let masterSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
            let masterStmt = try baseDAO.prepare(masterSQL)
            defer { baseDAO.finalize(masterStmt) }
            baseDAO.bindText(masterStmt, 1, tableName)
            
            let masterExists = sqlite3_step(masterStmt) == SQLITE_ROW
            print("🔍 DEBUG: sqlite_master check result: \(masterExists)")
            
            if masterExists != exists {
                print("⚠️ DEBUG: Inconsistency between PRAGMA and sqlite_master!")
                return masterExists // Trust sqlite_master if there's a conflict
            }
        }
        
        return exists
    }
    
    public func getTableSchema(_ tableName: String) throws -> [String: String] {
        let sql = "PRAGMA table_info(\(tableName))"
        let stmt = try baseDAO.prepare(sql)
        defer { baseDAO.finalize(stmt) }
        
        var schema: [String: String] = [:]
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let columnName = stmt.columnText(1) ?? ""
            let columnType = stmt.columnText(2) ?? ""
            schema[columnName] = columnType
        }
        
        return schema
    }
    
    public func getUserVersion() throws -> Int {
        let stmt = try baseDAO.prepare("PRAGMA user_version")
        defer { baseDAO.finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DAOError.databaseError("Failed to get user version")
        }
        
        return stmt.columnInt(0)
    }
    
    public func setUserVersion(_ version: Int) throws {
        try baseDAO.exec("PRAGMA user_version = \(version)")
    }
}
