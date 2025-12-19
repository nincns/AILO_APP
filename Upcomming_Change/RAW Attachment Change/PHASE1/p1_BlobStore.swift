// AILO_APP/Helpers/Storage/BlobStore.swift
// PHASE 1: Blob Storage Manager
// Handles deduplicated binary storage with SHA256-based addressing

import Foundation
import CryptoKit

public enum BlobStoreError: LocalizedError {
    case storageNotInitialized
    case blobNotFound(String)
    case invalidHash(String)
    case writeFailed(String)
    case readFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .storageNotInitialized: return "Blob storage not initialized"
        case .blobNotFound(let id): return "Blob not found: \(id)"
        case .invalidHash(let msg): return "Invalid hash: \(msg)"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        }
    }
}

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

/// Manages deduplicated blob storage with SHA256-based addressing
/// Thread-safe for concurrent reads, serialized writes
public final class BlobStore: Sendable {
    
    // MARK: - Properties
    
    private let baseDirectory: URL
    private let fileManager: FileManager
    private let queue: DispatchQueue
    
    // MARK: - Initialization
    
    /// Initialize blob store with base directory
    /// - Parameter baseDirectory: Root directory for blob storage (defaults to app support)
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
        
        // Create base directory if needed
        try createBaseDirectory()
    }
    
    // MARK: - Public API
    
    /// Store data and return SHA256 hash
    /// Automatically deduplicates - returns existing hash if data already stored
    /// - Parameter data: Binary data to store
    /// - Returns: SHA256 hash as hex string (lowercase)
    public func store(_ data: Data) throws -> String {
        let hash = calculateSHA256(data)
        let path = storagePath(for: hash)
        
        return try queue.sync(flags: .barrier) {
            // Check if already exists
            if fileManager.fileExists(atPath: path.path) {
                print("✅ [BlobStore] Blob already exists (dedup): \(hash)")
                return hash
            }
            
            // Create subdirectory if needed
            let dir = path.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            
            // Write data
            try data.write(to: path, options: .atomic)
            print("✅ [BlobStore] Stored new blob: \(hash) (\(data.count) bytes)")
            
            return hash
        }
    }
    
    /// Retrieve data by SHA256 hash
    /// - Parameter blobId: SHA256 hash (hex string)
    /// - Returns: Binary data, or nil if not found
    public func retrieve(_ blobId: String) throws -> Data? {
        let path = storagePath(for: blobId)
        
        return try queue.sync {
            guard fileManager.fileExists(atPath: path.path) else {
                return nil
            }
            
            do {
                let data = try Data(contentsOf: path)
                
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
    
    /// Delete blob from filesystem (use with caution - check refCount first)
    /// - Parameter blobId: SHA256 hash to delete
    public func delete(_ blobId: String) throws {
        let path = storagePath(for: blobId)
        
        try queue.sync(flags: .barrier) {
            guard fileManager.fileExists(atPath: path.path) else {
                print("⚠️ [BlobStore] Blob not found for deletion: \(blobId)")
                return
            }
            
            try fileManager.removeItem(at: path)
            print("🗑️ [BlobStore] Deleted blob: \(blobId)")
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
                   fileName.allSatisfy({ $0.isHexDigit }) {
                    blobs.append(fileName)
                }
            }
            
            return blobs
        }
    }
    
    /// Calculate storage metrics
    /// - Returns: Metrics about storage usage
    public func getMetrics() throws -> BlobStorageMetrics {
        let blobs = try listAllBlobs()
        var totalSize = 0
        
        for blobId in blobs {
            let path = storagePath(for: blobId)
            if let attrs = try? fileManager.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? Int {
                totalSize += size
            }
        }
        
        return BlobStorageMetrics(
            totalBlobs: blobs.count,
            totalSizeBytes: totalSize,
            uniqueBlobs: blobs.count,
            dedupSavingsBytes: 0, // To be calculated from DB refCounts
            orphanedBlobs: 0      // To be calculated from DB comparison
        )
    }
    
    // MARK: - Helper Methods
    
    /// Calculate SHA256 hash of data
    private func calculateSHA256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Get filesystem path for blob ID
    /// Uses hierarchical structure: aa/bb/aabbccdd...
    private func storagePath(for blobId: String) -> URL {
        let normalized = blobId.lowercased()
        
        // Create 2-level hierarchy: first 2 chars, next 2 chars
        let level1 = String(normalized.prefix(2))
        let level2 = String(normalized.dropFirst(2).prefix(2))
        
        return baseDirectory
            .appendingPathComponent(level1, isDirectory: true)
            .appendingPathComponent(level2, isDirectory: true)
            .appendingPathComponent(normalized, isDirectory: false)
    }
    
    /// Create base directory structure
    private func createBaseDirectory() throws {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            print("✅ [BlobStore] Created base directory: \(baseDirectory.path)")
        }
    }
}

// MARK: - Character Extension

private extension Character {
    var isHexDigit: Bool {
        return self.isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
