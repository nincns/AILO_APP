// BlobStore.swift
// Hash-basierter Blob Storage Service mit Deduplizierung
// Phase 1, 4, 6: Core blob storage functionality

import Foundation
import CryptoKit

// MARK: - Blob Store Protocol

protocol BlobStoreProtocol {
    func store(_ data: Data, messageId: UUID, partId: String) throws -> String
    func retrieve(blobId: String) throws -> Data?
    func exists(blobId: String) -> Bool
    func delete(blobId: String) throws
    func calculateHash(_ data: Data) -> String
    func getStorageMetrics() throws -> StorageMetrics
}

// MARK: - Storage Metrics

struct StorageMetrics {
    let totalBlobs: Int
    let totalSize: Int64
    let deduplicatedCount: Int
    let savedSpace: Int64
}

// MARK: - Blob Store Implementation

class BlobStore: BlobStoreProtocol {
    
    private let basePath: URL
    private let writeDAO: MailWriteDAO
    private let readDAO: MailReadDAO
    private let queue = DispatchQueue(label: "blobstore.io", attributes: .concurrent)
    
    // Cache for frequently accessed blobs
    private var cache = NSCache<NSString, NSData>()
    
    init(basePath: URL, writeDAO: MailWriteDAO, readDAO: MailReadDAO) {
        self.basePath = basePath
        self.writeDAO = writeDAO
        self.readDAO = readDAO
        
        // Configure cache
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
        // Ensure base directory exists
        try? FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)
    }
    
    // MARK: - Store Blob with Deduplication
    
    func store(_ data: Data, messageId: UUID, partId: String) throws -> String {
        let hash = calculateHash(data)
        let blobId = hash
        
        return try queue.sync(flags: .barrier) {
            // Check if blob already exists (deduplication)
            if !exists(blobId: blobId) {
                // Store to filesystem
                let path = blobPath(for: blobId)
                let directory = path.deletingLastPathComponent()
                
                try FileManager.default.createDirectory(at: directory,
                                                       withIntermediateDirectories: true)
                
                // Write with atomic operation for safety
                try data.write(to: path, options: .atomic)
                
                // Store metadata in database
                try storeBlobMetadata(blobId: blobId, hash: hash, size: data.count)
                
                print("✅ [BlobStore] Stored new blob: \(blobId) (\(data.count) bytes)")
            } else {
                // Increment reference count for existing blob
                try incrementBlobReference(blobId: blobId)
                print("♻️ [BlobStore] Reusing existing blob: \(blobId) (dedup)")
            }
            
            // Link blob to message part
            try linkBlobToMessage(blobId: blobId, messageId: messageId, partId: partId)
            
            // Add to cache
            cache.setObject(data as NSData, forKey: blobId as NSString, cost: data.count)
            
            return blobId
        }
    }
    
    // MARK: - Retrieve Blob
    
    func retrieve(blobId: String) throws -> Data? {
        // Check cache first
        if let cached = cache.object(forKey: blobId as NSString) {
            print("💨 [BlobStore] Retrieved from cache: \(blobId)")
            try updateBlobAccess(blobId: blobId)
            return cached as Data
        }
        
        return try queue.sync {
            let path = blobPath(for: blobId)
            
            guard FileManager.default.fileExists(atPath: path.path) else {
                print("⚠️ [BlobStore] Blob not found: \(blobId)")
                return nil
            }
            
            let data = try Data(contentsOf: path)
            
            // Update access time
            try updateBlobAccess(blobId: blobId)
            
            // Add to cache
            cache.setObject(data as NSData, forKey: blobId as NSString, cost: data.count)
            
            print("📁 [BlobStore] Retrieved from disk: \(blobId)")
            return data
        }
    }
    
    // MARK: - Check Existence
    
    func exists(blobId: String) -> Bool {
        // Check cache first
        if cache.object(forKey: blobId as NSString) != nil {
            return true
        }
        
        // Check filesystem
        let path = blobPath(for: blobId)
        return FileManager.default.fileExists(atPath: path.path)
    }
    
    // MARK: - Delete Blob
    
    func delete(blobId: String) throws {
        try queue.sync(flags: .barrier) {
            // Check reference count before deleting
            let refCount = try getBlobReferenceCount(blobId: blobId)
            
            if refCount <= 1 {
                // Safe to delete physical file
                let path = blobPath(for: blobId)
                
                if FileManager.default.fileExists(atPath: path.path) {
                    try FileManager.default.removeItem(at: path)
                    print("🗑 [BlobStore] Deleted blob: \(blobId)")
                }
                
                // Remove from cache
                cache.removeObject(forKey: blobId as NSString)
                
                // Remove metadata
                try deleteBlobMetadata(blobId: blobId)
            } else {
                // Just decrement reference count
                try decrementBlobReference(blobId: blobId)
                print("📉 [BlobStore] Decremented ref count for: \(blobId) (now: \(refCount - 1))")
            }
        }
    }
    
    // MARK: - Hash Calculation
    
    func calculateHash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Storage Metrics
    
    func getStorageMetrics() throws -> StorageMetrics {
        // Query database for metrics
        let metrics = try readDAO.getBlobStorageMetrics()
        
        // Calculate saved space from deduplication
        let savedSpace = Int64(metrics.deduplicatedCount) * Int64(metrics.averageSize)
        
        return StorageMetrics(
            totalBlobs: metrics.totalBlobs,
            totalSize: metrics.totalSize,
            deduplicatedCount: metrics.deduplicatedCount,
            savedSpace: savedSpace
        )
    }
    
    // MARK: - Private Helpers
    
    private func blobPath(for blobId: String) -> URL {
        // Use first 2 chars for directory hierarchy (like Git)
        // This prevents too many files in a single directory
        guard blobId.count >= 2 else {
            return basePath.appendingPathComponent(blobId)
        }
        
        let prefix = String(blobId.prefix(2))
        let suffix = String(blobId.dropFirst(2))
        
        return basePath
            .appendingPathComponent(prefix)
            .appendingPathComponent(suffix)
    }
    
    private func storeBlobMetadata(blobId: String, hash: String, size: Int) throws {
        try writeDAO.storeBlobMeta(blobId: blobId, hashSha256: hash, sizeBytes: size)
    }
    
    private func linkBlobToMessage(blobId: String, messageId: UUID, partId: String) throws {
        try writeDAO.updateMimePartBlobId(messageId: messageId, partId: partId, blobId: blobId)
    }
    
    private func getBlobReferenceCount(blobId: String) throws -> Int {
        guard let meta = try readDAO.getBlobMeta(blobId: blobId) else {
            return 0
        }
        return meta.referenceCount
    }
    
    private func incrementBlobReference(blobId: String) throws {
        try writeDAO.incrementBlobReference(blobId: blobId)
    }
    
    private func decrementBlobReference(blobId: String) throws {
        try writeDAO.decrementBlobReference(blobId: blobId)
    }
    
    private func updateBlobAccess(blobId: String) throws {
        try writeDAO.updateBlobAccess(blobId: blobId)
    }
    
    private func deleteBlobMetadata(blobId: String) throws {
        try writeDAO.deleteBlobMeta(blobId: blobId)
    }
}

// MARK: - Blob Store with RAW Message Support

extension BlobStore {
    
    /// Store complete RAW RFC822 message
    func storeRawMessage(_ data: Data, messageId: UUID) throws -> String {
        return try store(data, messageId: messageId, partId: "RAW")
    }
    
    /// Retrieve RAW RFC822 message
    func retrieveRawMessage(messageId: UUID) throws -> Data? {
        // Get blob_id from database
        guard let blobId = try readDAO.getRawBlobId(messageId: messageId) else {
            return nil
        }
        
        return try retrieve(blobId: blobId)
    }
    
    /// Store message part with automatic compression for text
    func storeMessagePart(_ data: Data, messageId: UUID, partId: String, mimeType: String) throws -> String {
        var dataToStore = data
        
        // Compress text content if beneficial
        if mimeType.hasPrefix("text/") && data.count > 1024 {
            if let compressed = compress(data), compressed.count < data.count * 0.8 {
                dataToStore = compressed
                print("🗜 [BlobStore] Compressed text part: \(data.count) → \(compressed.count) bytes")
            }
        }
        
        return try store(dataToStore, messageId: messageId, partId: partId)
    }
    
    private func compress(_ data: Data) -> Data? {
        return try? (data as NSData).compressed(using: .zlib) as Data
    }
}

// MARK: - Cleanup and Maintenance

extension BlobStore {
    
    /// Remove orphaned blobs (no references)
    func cleanupOrphaned() throws -> Int {
        var cleaned = 0
        
        let orphanedBlobs = try readDAO.getOrphanedBlobs()
        
        for blobId in orphanedBlobs {
            try delete(blobId: blobId)
            cleaned += 1
        }
        
        print("🧹 [BlobStore] Cleaned \(cleaned) orphaned blobs")
        return cleaned
    }
    
    /// Remove blobs not accessed for specified days
    func cleanupOldBlobs(olderThanDays: Int) throws -> Int {
        let cutoffDate = Date().addingTimeInterval(TimeInterval(-olderThanDays * 24 * 60 * 60))
        let oldBlobs = try readDAO.getBlobsOlderThan(date: cutoffDate)
        
        var cleaned = 0
        for blobId in oldBlobs {
            try delete(blobId: blobId)
            cleaned += 1
        }
        
        print("🧹 [BlobStore] Cleaned \(cleaned) old blobs")
        return cleaned
    }
    
    /// Verify blob integrity
    func verifyIntegrity() throws -> [String] {
        var corrupted: [String] = []
        
        let allBlobs = try readDAO.getAllBlobIds()
        
        for blobId in allBlobs {
            if let data = try retrieve(blobId: blobId) {
                let calculatedHash = calculateHash(data)
                if calculatedHash != blobId {
                    corrupted.append(blobId)
                    print("⚠️ [BlobStore] Corrupted blob detected: \(blobId)")
                }
            }
        }
        
        return corrupted
    }
}
