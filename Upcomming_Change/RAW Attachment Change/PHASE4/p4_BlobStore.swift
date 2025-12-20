// AILO_APP/Core/Storage/BlobStore_Phase4.swift
// PHASE 4: Blob Storage with SHA256 Deduplication
// Manages binary data (RAW mails, attachments) with automatic deduplication

import Foundation
import CryptoKit

// MARK: - Blob Store Protocol

/// Phase 4: Blob storage with deduplication and ref-counting
public protocol BlobStoreProtocol {
    /// Store data and return SHA256 hash
    func store(_ data: Data) throws -> String
    
    /// Retrieve data by hash
    func retrieve(_ hash: String) throws -> Data?
    
    /// Increment reference count
    func incrementRefCount(_ hash: String) throws
    
    /// Decrement reference count
    func decrementRefCount(_ hash: String) throws
    
    /// Remove blobs with ref_count = 0
    func garbageCollect() throws -> Int
    
    /// Get storage statistics
    func getStats() throws -> BlobStats
}

// MARK: - Supporting Types

/// Statistics about blob storage
public struct BlobStats: Sendable {
    public let totalBlobs: Int
    public let totalSize: Int64
    public let deduplicatedCount: Int
    public let avgBlobSize: Int64
    
    public init(totalBlobs: Int, totalSize: Int64, deduplicatedCount: Int) {
        self.totalBlobs = totalBlobs
        self.totalSize = totalSize
        self.deduplicatedCount = deduplicatedCount
        self.avgBlobSize = totalBlobs > 0 ? totalSize / Int64(totalBlobs) : 0
    }
}

// MARK: - File System Blob Store

/// Phase 4: File-based blob storage with hierarchical directory structure
/// Uses SHA256 hash for deduplication: /aa/bb/aabbcc...
public class FileSystemBlobStore: BlobStoreProtocol {
    
    private let baseDirectory: URL
    private let metadataStore: BlobMetadataStore
    
    // MARK: - Initialization
    
    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        self.metadataStore = try BlobMetadataStore(dbPath: baseDirectory.appendingPathComponent("metadata.db").path)
        
        // Ensure base directory exists
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Storage Operations
    
    /// Store blob and return hash
    /// - Parameter data: Binary data to store
    /// - Returns: SHA256 hash (also serves as unique ID)
    public func store(_ data: Data) throws -> String {
        // Calculate hash
        let hash = calculateSHA256(data)
        
        // Check if already exists (deduplication)
        if try metadataStore.exists(hash: hash) {
            print("🔄 [BlobStore Phase4] Dedup hit for hash: \(hash.prefix(8))...")
            try metadataStore.incrementRefCount(hash: hash)
            return hash
        }
        
        // Create hierarchical path: /aa/bb/aabbcc...
        let path = hierarchicalPath(for: hash)
        let fileURL = baseDirectory.appendingPathComponent(path)
        
        // Ensure directory exists
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), 
                                               withIntermediateDirectories: true)
        
        // Write file
        try data.write(to: fileURL, options: .atomic)
        
        // Register in metadata store
        try metadataStore.register(hash: hash, sizeBytes: data.count, path: path)
        
        print("💾 [BlobStore Phase4] Stored blob: \(hash.prefix(8))... (\(data.count) bytes)")
        
        return hash
    }
    
    /// Retrieve blob by hash
    /// - Parameter hash: SHA256 hash
    /// - Returns: Binary data or nil if not found
    public func retrieve(_ hash: String) throws -> Data? {
        guard let metadata = try metadataStore.get(hash: hash) else {
            return nil
        }
        
        let fileURL = baseDirectory.appendingPathComponent(metadata.path)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("⚠️ [BlobStore Phase4] Blob file missing: \(hash.prefix(8))...")
            return nil
        }
        
        return try Data(contentsOf: fileURL)
    }
    
    /// Increment reference count
    public func incrementRefCount(_ hash: String) throws {
        try metadataStore.incrementRefCount(hash: hash)
    }
    
    /// Decrement reference count
    public func decrementRefCount(_ hash: String) throws {
        try metadataStore.decrementRefCount(hash: hash)
    }
    
    /// Remove blobs with ref_count = 0
    /// - Returns: Number of blobs removed
    public func garbageCollect() throws -> Int {
        let orphans = try metadataStore.getOrphans()
        
        var removedCount = 0
        for metadata in orphans {
            let fileURL = baseDirectory.appendingPathComponent(metadata.path)
            
            // Delete file
            try? FileManager.default.removeItem(at: fileURL)
            
            // Remove from metadata
            try metadataStore.remove(hash: metadata.hash)
            
            removedCount += 1
        }
        
        if removedCount > 0 {
            print("🗑️ [BlobStore Phase4] Garbage collected \(removedCount) blobs")
        }
        
        return removedCount
    }
    
    /// Get storage statistics
    public func getStats() throws -> BlobStats {
        return try metadataStore.getStats()
    }
    
    // MARK: - Helper Methods
    
    /// Calculate SHA256 hash of data
    private func calculateSHA256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Create hierarchical path from hash
    /// Example: aabbccdd... → aa/bb/aabbccdd...
    private func hierarchicalPath(for hash: String) -> String {
        let prefix1 = String(hash.prefix(2))
        let prefix2 = String(hash.dropFirst(2).prefix(2))
        return "\(prefix1)/\(prefix2)/\(hash)"
    }
}

// MARK: - Blob Metadata Store

/// SQLite-based metadata for blob storage
private class BlobMetadataStore {
    
    private let dbPath: String
    private var db: OpaquePointer?
    
    // MARK: - Initialization
    
    init(dbPath: String) throws {
        self.dbPath = dbPath
        
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw BlobStoreError.initializationFailed
        }
        
        try createTables()
    }
    
    deinit {
        sqlite3_close(db)
    }
    
    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS blob_metadata (
            hash TEXT PRIMARY KEY,
            size_bytes INTEGER NOT NULL,
            path TEXT NOT NULL,
            ref_count INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            last_accessed INTEGER NOT NULL
        );
        
        CREATE INDEX IF NOT EXISTS idx_blob_refcount
        ON blob_metadata (ref_count) WHERE ref_count = 0;
        """
        
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw BlobStoreError.tableCreationFailed
        }
    }
    
    // MARK: - Operations
    
    func exists(hash: String) throws -> Bool {
        let sql = "SELECT 1 FROM blob_metadata WHERE hash = ? LIMIT 1;"
        var stmt: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    
    func register(hash: String, sizeBytes: Int, path: String) throws {
        let sql = """
        INSERT INTO blob_metadata (hash, size_bytes, path, ref_count, created_at, last_accessed)
        VALUES (?, ?, ?, 1, ?, ?);
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.insertFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        let now = Int64(Date().timeIntervalSince1970)
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, Int64(sizeBytes))
        sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 4, now)
        sqlite3_bind_int64(stmt, 5, now)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BlobStoreError.insertFailed
        }
    }
    
    func get(hash: String) throws -> BlobMetadata? {
        let sql = """
        SELECT hash, size_bytes, path, ref_count, created_at, last_accessed
        FROM blob_metadata WHERE hash = ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        return BlobMetadata(
            hash: String(cString: sqlite3_column_text(stmt, 0)),
            sizeBytes: Int(sqlite3_column_int64(stmt, 1)),
            path: String(cString: sqlite3_column_text(stmt, 2)),
            refCount: Int(sqlite3_column_int(stmt, 3)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4))),
            lastAccessed: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
        )
    }
    
    func incrementRefCount(hash: String) throws {
        let sql = """
        UPDATE blob_metadata 
        SET ref_count = ref_count + 1, last_accessed = ?
        WHERE hash = ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.updateFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        let now = Int64(Date().timeIntervalSince1970)
        
        sqlite3_bind_int64(stmt, 1, now)
        sqlite3_bind_text(stmt, 2, (hash as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BlobStoreError.updateFailed
        }
    }
    
    func decrementRefCount(hash: String) throws {
        let sql = """
        UPDATE blob_metadata 
        SET ref_count = MAX(0, ref_count - 1)
        WHERE hash = ?;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.updateFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BlobStoreError.updateFailed
        }
    }
    
    func getOrphans() throws -> [BlobMetadata] {
        let sql = """
        SELECT hash, size_bytes, path, ref_count, created_at, last_accessed
        FROM blob_metadata WHERE ref_count = 0;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        var orphans: [BlobMetadata] = []
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let metadata = BlobMetadata(
                hash: String(cString: sqlite3_column_text(stmt, 0)),
                sizeBytes: Int(sqlite3_column_int64(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2)),
                refCount: Int(sqlite3_column_int(stmt, 3)),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 4))),
                lastAccessed: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 5)))
            )
            orphans.append(metadata)
        }
        
        return orphans
    }
    
    func remove(hash: String) throws {
        let sql = "DELETE FROM blob_metadata WHERE hash = ?;"
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.deleteFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, nil)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BlobStoreError.deleteFailed
        }
    }
    
    func getStats() throws -> BlobStats {
        let sql = """
        SELECT 
            COUNT(*) as total,
            SUM(size_bytes) as total_size,
            COUNT(DISTINCT hash) - COUNT(*) as dedup_count
        FROM blob_metadata;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BlobStoreError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return BlobStats(totalBlobs: 0, totalSize: 0, deduplicatedCount: 0)
        }
        
        return BlobStats(
            totalBlobs: Int(sqlite3_column_int(stmt, 0)),
            totalSize: sqlite3_column_int64(stmt, 1),
            deduplicatedCount: Int(sqlite3_column_int(stmt, 2))
        )
    }
}

// MARK: - Supporting Types

/// Metadata about a stored blob
private struct BlobMetadata {
    let hash: String
    let sizeBytes: Int
    let path: String
    let refCount: Int
    let createdAt: Date
    let lastAccessed: Date
}

// MARK: - Errors

public enum BlobStoreError: Error, LocalizedError {
    case initializationFailed
    case tableCreationFailed
    case queryFailed
    case insertFailed
    case updateFailed
    case deleteFailed
    case fileNotFound
    case hashMismatch
    
    public var errorDescription: String? {
        switch self {
        case .initializationFailed: return "Failed to initialize blob store"
        case .tableCreationFailed: return "Failed to create metadata tables"
        case .queryFailed: return "Metadata query failed"
        case .insertFailed: return "Failed to insert blob metadata"
        case .updateFailed: return "Failed to update blob metadata"
        case .deleteFailed: return "Failed to delete blob"
        case .fileNotFound: return "Blob file not found"
        case .hashMismatch: return "Hash verification failed"
        }
    }
}

// MARK: - Usage Documentation

/*
 BLOB STORE USAGE (Phase 4)
 ===========================
 
 INITIALIZATION:
 ```swift
 let blobsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
     .appendingPathComponent("Blobs")
 
 let blobStore = try FileSystemBlobStore(baseDirectory: blobsDir)
 ```
 
 STORE BLOB:
 ```swift
 let data = emailRaw.data(using: .utf8)!
 let hash = try blobStore.store(data)
 
 // Save hash in database
 try writeDAO.storeBody(
     ...,
     rawBlobId: hash
 )
 ```
 
 RETRIEVE BLOB:
 ```swift
 if let data = try blobStore.retrieve(hash) {
     let raw = String(data: data, encoding: .utf8)
 }
 ```
 
 DEDUPLICATION:
 ```swift
 // Same data = same hash
 let hash1 = try blobStore.store(data)  // New blob
 let hash2 = try blobStore.store(data)  // Dedup hit! ref_count++
 
 // hash1 == hash2
 ```
 
 GARBAGE COLLECTION:
 ```swift
 // When deleting message:
 try blobStore.decrementRefCount(hash)
 
 // Periodic cleanup:
 let removed = try blobStore.garbageCollect()
 print("Removed \(removed) orphaned blobs")
 ```
 
 STATISTICS:
 ```swift
 let stats = try blobStore.getStats()
 print("Total: \(stats.totalBlobs) blobs")
 print("Size: \(stats.totalSize) bytes")
 print("Deduplicated: \(stats.deduplicatedCount)")
 ```
 */
