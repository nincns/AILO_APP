// AILO_APP/Core/Storage/BlobStore_Phase4.swift
// PHASE 4: Blob Storage with SHA256 Deduplication
// Manages binary data (RAW mails, attachments) with automatic deduplication

import Foundation
import CryptoKit
import SQLite3

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

/// Virus scan status enumeration
public enum VirusScanStatus: String, CaseIterable, Sendable {
    case pending = "pending"
    case clean = "clean"
    case infected = "infected"
    case quarantined = "quarantined"
    case scanError = "scan_error"
    case skipped = "skipped"
    
    public var isAllowedToDownload: Bool {
        switch self {
        case .clean, .pending, .skipped:
            return true
        case .infected, .quarantined, .scanError:
            return false
        }
    }
}

/// Attachment security information
public struct AttachmentSecurityInfo: Sendable {
    public let virusScanStatus: VirusScanStatus
    public let scanDate: Date?
    public let quarantineReason: String?
    public let scanDetails: String?
    
    public init(virusScanStatus: VirusScanStatus, scanDate: Date? = nil, 
                quarantineReason: String? = nil, scanDetails: String? = nil) {
        self.virusScanStatus = virusScanStatus
        self.scanDate = scanDate
        self.quarantineReason = quarantineReason
        self.scanDetails = scanDetails
    }
}

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
    case storageNotInitialized
    case blobNotFound(String)
    case invalidHash(String)
    case writeFailed(String)
    case readFailed(String)
    
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
        case .storageNotInitialized: return "Blob storage not initialized"
        case .blobNotFound(let id): return "Blob not found: \(id)"
        case .invalidHash(let msg): return "Invalid hash: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        }
    }
}

// MARK: - File System Blob Store

/// Phase 4: File-based blob storage with hierarchical directory structure
/// Uses SHA256 hash for deduplication: /aa/bb/aabbcc...
public final class BlobStore: BlobStoreProtocol, Sendable {
    
    private let baseDirectory: URL
    private let metadataStore: BlobMetadataStore
    private let fileManager: FileManager
    private let queue: DispatchQueue
    
    // MARK: - Initialization
    
    public init(baseDirectory: URL? = nil) throws {
        self.fileManager = FileManager.default
        
        // Default to app support directory
        if let baseDir = baseDirectory {
            self.baseDirectory = baseDir
        } else {
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw BlobStoreError.storageNotInitialized
            }
            self.baseDirectory = appSupport.appendingPathComponent("BlobStore", isDirectory: true)
        }
        
        self.queue = DispatchQueue(label: "com.ailo.blobstore", attributes: .concurrent)
        self.metadataStore = try BlobMetadataStore(dbPath: self.baseDirectory.appendingPathComponent("metadata.db").path)
        
        // Ensure base directory exists
        try fileManager.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Storage Operations
    
    /// Store data and return SHA256 hash
    /// Automatically deduplicates - returns existing hash if data already stored
    /// - Parameter data: Binary data to store
    /// - Returns: SHA256 hash as hex string (lowercase)
    public func store(_ data: Data) throws -> String {
        // Calculate hash
        let hash = calculateSHA256(data)
        
        return try queue.sync(flags: .barrier) {
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
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), 
                                           withIntermediateDirectories: true)
            
            // Write file
            try data.write(to: fileURL, options: .atomic)
            
            // Register in metadata store
            try metadataStore.register(hash: hash, sizeBytes: data.count, path: path)
            
            print("💾 [BlobStore Phase4] Stored blob: \(hash.prefix(8))... (\(data.count) bytes)")
            
            return hash
        }
    }
    
    /// Retrieve data by SHA256 hash
    /// - Parameter blobId: SHA256 hash (hex string)
    /// - Returns: Binary data, or nil if not found
    public func retrieve(_ blobId: String) throws -> Data? {
        return try queue.sync {
            guard let metadata = try metadataStore.get(hash: blobId) else {
                return nil
            }
            
            let fileURL = baseDirectory.appendingPathComponent(metadata.path)
            
            guard fileManager.fileExists(atPath: fileURL.path) else {
                print("⚠️ [BlobStore Phase4] Blob file missing: \(blobId.prefix(8))...")
                return nil
            }
            
            do {
                let data = try Data(contentsOf: fileURL)
                
                // Verify integrity
                let hash = calculateSHA256(data)
                guard hash == blobId.lowercased() else {
                    throw BlobStoreError.invalidHash("Stored data hash mismatch: expected \(blobId), got \(hash)")
                }
                
                return data
            } catch {
                throw BlobStoreError.readFailed("Failed to read blob \(blobId): \(error)")
            }
        }
    }
    
    /// Increment reference count
    public func incrementRefCount(_ hash: String) throws {
        try queue.sync(flags: .barrier) {
            try metadataStore.incrementRefCount(hash: hash)
        }
    }
    
    /// Decrement reference count
    public func decrementRefCount(_ hash: String) throws {
        try queue.sync(flags: .barrier) {
            try metadataStore.decrementRefCount(hash: hash)
        }
    }
    
    /// Delete blob from filesystem (use with caution - check refCount first)
    /// - Parameter blobId: SHA256 hash to delete
    public func delete(_ blobId: String) throws {
        try queue.sync(flags: .barrier) {
            guard let metadata = try metadataStore.get(hash: blobId) else {
                print("⚠️ [BlobStore] Blob not found for deletion: \(blobId)")
                return
            }
            
            let fileURL = baseDirectory.appendingPathComponent(metadata.path)
            
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            
            try metadataStore.remove(hash: blobId)
            print("🗑️ [BlobStore] Deleted blob: \(blobId)")
        }
    }
    
    /// Remove blobs with ref_count = 0
    /// - Returns: Number of blobs removed
    public func garbageCollect() throws -> Int {
        return try queue.sync(flags: .barrier) {
            let orphans = try metadataStore.getOrphans()
            
            var removedCount = 0
            for metadata in orphans {
                let fileURL = baseDirectory.appendingPathComponent(metadata.path)
                
                // Delete file
                try? fileManager.removeItem(at: fileURL)
                
                // Remove from metadata
                try metadataStore.remove(hash: metadata.hash)
                
                removedCount += 1
            }
            
            if removedCount > 0 {
                print("🗑️ [BlobStore Phase4] Garbage collected \(removedCount) blobs")
            }
            
            return removedCount
        }
    }
    
    /// Get storage statistics
    public func getStats() throws -> BlobStats {
        return try queue.sync {
            return try metadataStore.getStats()
        }
    }
    
    
    /// Get all stored blob IDs
    /// - Returns: Array of SHA256 hashes
    public func listAllBlobs() throws -> [String] {
        return try queue.sync {
            var blobs: [String] = []
            
            // Traverse all subdirectories
            let enumerator = fileManager.enumerator(at: baseDirectory, includingPropertiesForKeys: nil)
            
            while let url = enumerator?.nextObject() as? URL {
                // Only consider files in 2-level subdirectories (aa/bb/aabbcc...)
                let components = url.pathComponents
                if components.count >= 3,
                   let fileName = components.last,
                   fileName.count == 64, // SHA256 hex length
                   fileName.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
                    blobs.append(fileName)
                }
            }
            
            return blobs
        }
    }
    
    /// Calculate storage metrics (legacy compatibility)
    /// - Returns: Metrics about storage usage
    public func getMetrics() throws -> BlobStorageMetrics {
        let stats = try getStats()
        return BlobStorageMetrics(
            totalBlobs: stats.totalBlobs,
            totalSizeBytes: Int(stats.totalSize),
            uniqueBlobs: stats.totalBlobs,
            dedupSavingsBytes: Int(stats.deduplicatedCount),
            orphanedBlobs: 0
        )
    }
    
    // MARK: - Helper Methods
    
    /// Store data with a specific hash (internal method)
    private func store(data: Data, hash: String) throws {
        let path = hierarchicalPath(for: hash)
        let fileURL = baseDirectory.appendingPathComponent(path)
        
        // Ensure directory exists
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), 
                                       withIntermediateDirectories: true)
        
        // Write file
        try data.write(to: fileURL, options: .atomic)
        
        // Register in metadata store
        try metadataStore.register(hash: hash, sizeBytes: data.count, path: path)
    }
    
    /// Resolve path for hash (internal method)
    private func resolvePath(for hash: String) throws -> URL {
        guard let metadata = try metadataStore.get(hash: hash) else {
            throw BlobStoreError.blobNotFound(hash)
        }
        return baseDirectory.appendingPathComponent(metadata.path)
    }
    
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
    
    /// Get filesystem path for blob ID (legacy compatibility)
    /// Uses hierarchical structure: aa/bb/aabbccdd...
    private func storagePath(for blobId: String) -> URL {
        let path = hierarchicalPath(for: blobId)
        return baseDirectory.appendingPathComponent(path)
    }
}

// MARK: - BlobStore Security Extensions (Phase 6)

extension BlobStore {
    
    // MARK: - Quarantine Management
    
    /// Move blob to quarantine storage
    func quarantineBlob(hash: String, reason: String) throws {
        print("🔒 [BLOBSTORE] Quarantining blob \(hash.prefix(8))...")
        
        // Get original blob
        guard let data = try retrieve(hash) else {
            throw NSError(domain: "BlobStore", code: 5001,
                         userInfo: [NSLocalizedDescriptionKey: "Blob not found for quarantine"])
        }
        
        // Create quarantine directory
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        try FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        
        // Move to quarantine with metadata
        let quarantinePath = quarantineDir.appendingPathComponent(hash)
        try data.write(to: quarantinePath)
        
        // Write quarantine metadata
        let metadataPath = quarantinePath.appendingPathExtension("meta")
        let metadata = [
            "original_hash": hash,
            "quarantine_date": ISO8601DateFormatter().string(from: Date()),
            "reason": reason
        ]
        
        if let metadataData = try? JSONEncoder().encode(metadata) {
            try metadataData.write(to: metadataPath)
        }
        
        // Delete original blob
        let originalPath = try resolvePath(for: hash)
        try? FileManager.default.removeItem(at: originalPath)
        
        print("✅ [BLOBSTORE] Blob quarantined: \(reason)")
    }
    
    /// Restore blob from quarantine
    func restoreFromQuarantine(hash: String) throws {
        print("🔓 [BLOBSTORE] Restoring blob \(hash.prefix(8)) from quarantine...")
        
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        let quarantinePath = quarantineDir.appendingPathComponent(hash)
        
        guard FileManager.default.fileExists(atPath: quarantinePath.path) else {
            throw NSError(domain: "BlobStore", code: 5002,
                         userInfo: [NSLocalizedDescriptionKey: "Blob not in quarantine"])
        }
        
        // Read quarantined data
        let data = try Data(contentsOf: quarantinePath)
        
        // Store back to normal location
        try store(data: data, hash: hash)
        
        // Remove quarantine files
        try FileManager.default.removeItem(at: quarantinePath)
        let metadataPath = quarantinePath.appendingPathExtension("meta")
        try? FileManager.default.removeItem(at: metadataPath)
        
        print("✅ [BLOBSTORE] Blob restored from quarantine")
    }
    
    /// Delete quarantined blob permanently
    func deleteQuarantinedBlob(hash: String) throws {
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        let quarantinePath = quarantineDir.appendingPathComponent(hash)
        
        try FileManager.default.removeItem(at: quarantinePath)
        
        let metadataPath = quarantinePath.appendingPathExtension("meta")
        try? FileManager.default.removeItem(at: metadataPath)
        
        print("🗑️  [BLOBSTORE] Quarantined blob deleted permanently")
    }
    
    /// List all quarantined blobs
    func listQuarantinedBlobs() throws -> [String] {
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        
        guard FileManager.default.fileExists(atPath: quarantineDir.path) else {
            return []
        }
        
        let contents = try FileManager.default.contentsOfDirectory(
            at: quarantineDir,
            includingPropertiesForKeys: nil
        )
        
        // Filter out .meta files
        return contents
            .filter { !$0.pathExtension.contains("meta") }
            .map { $0.lastPathComponent }
    }
    
    // MARK: - Scan Status Tracking
    
    /// Mark blob as scanned
    func markBlobScanned(hash: String, status: VirusScanStatus, details: String? = nil) throws {
        let scanMetadataDir = baseDirectory.appendingPathComponent("scan_metadata")
        try FileManager.default.createDirectory(at: scanMetadataDir, withIntermediateDirectories: true)
        
        let metadataPath = scanMetadataDir.appendingPathComponent(hash)
        
        let metadata: [String: Any] = [
            "hash": hash,
            "scan_status": status.rawValue,
            "scan_date": ISO8601DateFormatter().string(from: Date()),
            "details": details ?? ""
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: metadata) {
            try data.write(to: metadataPath)
        }
    }
    
    /// Get scan status for blob
    func getScanStatus(hash: String) -> VirusScanStatus? {
        let scanMetadataDir = baseDirectory.appendingPathComponent("scan_metadata")
        let metadataPath = scanMetadataDir.appendingPathComponent(hash)
        
        guard FileManager.default.fileExists(atPath: metadataPath.path),
              let data = try? Data(contentsOf: metadataPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusString = json["scan_status"] as? String else {
            return nil
        }
        
        return VirusScanStatus(rawValue: statusString)
    }
    
    // MARK: - Secure Access
    
    /// Check if blob is safe to access
    func isBlobSafe(hash: String) -> Bool {
        // Check if quarantined
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        let quarantinePath = quarantineDir.appendingPathComponent(hash)
        
        if FileManager.default.fileExists(atPath: quarantinePath.path) {
            return false
        }
        
        // Check scan status
        if let status = getScanStatus(hash: hash) {
            return status.isAllowedToDownload
        }
        
        // Not scanned yet - allow but mark as pending
        return true
    }
    
    /// Retrieve blob only if safe
    func retrieveSafe(hash: String) throws -> Data? {
        guard isBlobSafe(hash: hash) else {
            throw NSError(domain: "BlobStore", code: 5003,
                         userInfo: [NSLocalizedDescriptionKey: "Blob is quarantined or unsafe"])
        }
        
        return try retrieve(hash)
    }
    
    // MARK: - Size Limits
    
    /// Check if blob exceeds size limit
    func checkSizeLimit(data: Data, limit: Int) -> Bool {
        return data.count <= limit
    }
    
    /// Store with size validation
    func storeSafe(data: Data, hash: String, maxSize: Int = 25 * 1024 * 1024) throws {
        guard checkSizeLimit(data: data, limit: maxSize) else {
            throw NSError(domain: "BlobStore", code: 5004,
                         userInfo: [NSLocalizedDescriptionKey: "Blob exceeds size limit: \(data.count) > \(maxSize)"])
        }
        
        try store(data: data, hash: hash)
    }
    
    // MARK: - Statistics
    
    /// Get quarantine statistics
    func getQuarantineStats() -> (count: Int, totalSize: Int64) {
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        
        guard FileManager.default.fileExists(atPath: quarantineDir.path),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: quarantineDir,
                includingPropertiesForKeys: [.fileSizeKey]
              ) else {
            return (0, 0)
        }
        
        let blobs = contents.filter { !$0.pathExtension.contains("meta") }
        let totalSize = blobs.reduce(Int64(0)) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int64 ?? 0
            return total + size
        }
        
        return (blobs.count, totalSize)
    }
    
    /// Get scan statistics
    func getScanStats() -> [VirusScanStatus: Int] {
        var stats: [VirusScanStatus: Int] = [:]
        
        let scanMetadataDir = baseDirectory.appendingPathComponent("scan_metadata")
        guard FileManager.default.fileExists(atPath: scanMetadataDir.path),
              let contents = try? FileManager.default.contentsOfDirectory(at: scanMetadataDir, includingPropertiesForKeys: nil) else {
            return stats
        }
        
        for metadataPath in contents {
            if let status = getScanStatus(hash: metadataPath.lastPathComponent) {
                stats[status, default: 0] += 1
            }
        }
        
        return stats
    }
    
    // MARK: - Cleanup
    
    /// Clean up old scan metadata (older than 30 days)
    func cleanupOldScanMetadata(olderThan days: Int = 30) throws {
        let scanMetadataDir = baseDirectory.appendingPathComponent("scan_metadata")
        guard FileManager.default.fileExists(atPath: scanMetadataDir.path) else {
            return
        }
        
        let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        let contents = try FileManager.default.contentsOfDirectory(
            at: scanMetadataDir,
            includingPropertiesForKeys: [.creationDateKey]
        )
        
        var deletedCount = 0
        
        for metadataPath in contents {
            let attributes = try FileManager.default.attributesOfItem(atPath: metadataPath.path)
            if let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try FileManager.default.removeItem(at: metadataPath)
                deletedCount += 1
            }
        }
        
        print("🧹 [BLOBSTORE] Cleaned up \(deletedCount) old scan metadata entries")
    }
    
    /// Clean up quarantine (older than 90 days)
    func cleanupOldQuarantine(olderThan days: Int = 90) throws {
        let quarantineDir = baseDirectory.appendingPathComponent("quarantine")
        guard FileManager.default.fileExists(atPath: quarantineDir.path) else {
            return
        }
        
        let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        let contents = try FileManager.default.contentsOfDirectory(
            at: quarantineDir,
            includingPropertiesForKeys: [.creationDateKey]
        )
        
        var deletedCount = 0
        
        for quarantinePath in contents {
            // Skip .meta files (will be deleted with parent)
            if quarantinePath.pathExtension.contains("meta") {
                continue
            }
            
            let attributes = try FileManager.default.attributesOfItem(atPath: quarantinePath.path)
            if let creationDate = attributes[.creationDate] as? Date,
               creationDate < cutoffDate {
                try FileManager.default.removeItem(at: quarantinePath)
                
                // Delete metadata too
                let metadataPath = quarantinePath.appendingPathExtension("meta")
                try? FileManager.default.removeItem(at: metadataPath)
                
                deletedCount += 1
            }
        }
        
        print("🧹 [BLOBSTORE] Cleaned up \(deletedCount) old quarantined blobs")
    }
}

// MARK: - Legacy Support

/// Legacy metrics structure for backward compatibility
public struct BlobStorageMetrics: Sendable {
    public let totalBlobs: Int
    public let totalSizeBytes: Int
    public let uniqueBlobs: Int
    public let dedupSavingsBytes: Int
    public let orphanedBlobs: Int
    
    public init(totalBlobs: Int, totalSizeBytes: Int, uniqueBlobs: Int,
                dedupSavingsBytes: Int, orphanedBlobs: Int) {
        self.totalBlobs = totalBlobs
        self.totalSizeBytes = totalSizeBytes
        self.uniqueBlobs = uniqueBlobs
        self.dedupSavingsBytes = dedupSavingsBytes
        self.orphanedBlobs = orphanedBlobs
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
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, { _ in })
        
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
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, { _ in })
        sqlite3_bind_int64(stmt, 2, Int64(sizeBytes))
        sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, { _ in })
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
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, { _ in })
        
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
        sqlite3_bind_text(stmt, 2, (hash as NSString).utf8String, -1, { _ in })
        
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
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, { _ in })
        
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
        
        sqlite3_bind_text(stmt, 1, (hash as NSString).utf8String, -1, { _ in })
        
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



// MARK: - Usage Documentation

/*
 BLOB STORE USAGE (Phase 4)
 ===========================
 
 INITIALIZATION:
 ```swift
 let blobsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
     .appendingPathComponent("Blobs")
 
 let blobStore = try BlobStore(baseDirectory: blobsDir)
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

// MARK: - Phase 6 Security Extensions Usage

/*
 BLOBSTORE SECURITY EXTENSIONS (Phase 6)
 ========================================
 
 QUARANTINE BLOB:
 ```swift
 try blobStore.quarantineBlob(
     hash: blobHash,
     reason: "Virus detected: EICAR-Test-File"
 )
 ```
 
 RESTORE FROM QUARANTINE:
 ```swift
 try blobStore.restoreFromQuarantine(hash: blobHash)
 ```
 
 LIST QUARANTINED:
 ```swift
 let quarantined = try blobStore.listQuarantinedBlobs()
 print("Quarantined: \(quarantined.count) blobs")
 ```
 
 MARK AS SCANNED:
 ```swift
 try blobStore.markBlobScanned(
     hash: blobHash,
     status: .clean,
     details: "Scanned by ClamAV"
 )
 ```
 
 CHECK SAFETY:
 ```swift
 if blobStore.isBlobSafe(hash: blobHash) {
     let data = try blobStore.retrieveSafe(hash: blobHash)
 }
 ```
 
 SAFE STORAGE:
 ```swift
 try blobStore.storeSafe(
     data: attachmentData,
     hash: hash,
     maxSize: 25 * 1024 * 1024
 )
 ```
 
 STATISTICS:
 ```swift
 let (count, size) = blobStore.getQuarantineStats()
 print("Quarantine: \(count) blobs, \(size) bytes")
 
 let scanStats = blobStore.getScanStats()
 print("Clean: \(scanStats[.clean] ?? 0)")
 ```
 
 CLEANUP:
 ```swift
 // Clean scan metadata older than 30 days
 try blobStore.cleanupOldScanMetadata(olderThan: 30)
 
 // Clean quarantine older than 90 days
 try blobStore.cleanupOldQuarantine(olderThan: 90)
 ```
 
 FEATURES:
 - Quarantine management
 - Scan status tracking  
 - Safe retrieval (blocks quarantined)
 - Size limit enforcement
 - Statistics and monitoring
 - Automatic cleanup
 - Metadata persistence
 
 DIRECTORY STRUCTURE:
 /blobs/
   aa/
     bb/
       <hash> - Normal blobs
   quarantine/
     <hash> - Quarantined blobs
     <hash>.meta - Quarantine metadata
   scan_metadata/
     <hash> - Scan results
 */
