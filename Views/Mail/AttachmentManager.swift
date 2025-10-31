// AILO_APP/Core/Mail/AttachmentManager.swift
// File-based attachment management with deduplication and cleanup
// Stores attachments in ~/Documents/MailAttachments/{accountId}/{mailId}/

import Foundation
import CryptoKit
import OSLog

/// Manages attachment storage and retrieval from the file system
public class AttachmentManager {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ailo.mail", category: "AttachmentManager")
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    
    // Cache for frequently accessed attachments
    private let cache = NSCache<NSString, CachedAttachment>()
    private let cacheQueue = DispatchQueue(label: "attachment.cache.queue", attributes: .concurrent)
    
    // Cleanup configuration
    public struct CleanupPolicy {
        public let maxAge: TimeInterval      // Delete attachments older than this
        public let maxTotalSize: Int64       // Keep total attachment storage under this limit
        public let maxOrphanAge: TimeInterval // Delete orphaned attachments after this time
        
        public static let `default` = CleanupPolicy(
            maxAge: 90 * 24 * 3600,        // 90 days
            maxTotalSize: 2 * 1024 * 1024 * 1024, // 2 GB
            maxOrphanAge: 7 * 24 * 3600    // 7 days
        )
        
        public init(maxAge: TimeInterval, maxTotalSize: Int64, maxOrphanAge: TimeInterval) {
            self.maxAge = maxAge
            self.maxTotalSize = maxTotalSize
            self.maxOrphanAge = maxOrphanAge
        }
    }
    
    // MARK: - Initialization
    
    public init() throws {
        // Create base directory in Documents/MailAttachments/
        let documentsURL = try fileManager.url(for: .documentDirectory, 
                                             in: .userDomainMask, 
                                             appropriateFor: nil, 
                                             create: true)
        self.baseDirectory = documentsURL.appendingPathComponent("MailAttachments")
        
        // Ensure base directory exists
        try createDirectoryIfNeeded(baseDirectory)
        
        // Configure cache
        cache.countLimit = 100 // Keep 100 attachments in memory
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB memory limit
        
        logger.info("AttachmentManager initialized with base directory: \(self.baseDirectory.path)")
    }
    
    // MARK: - Public Interface
    
    /// Save attachment data to file system with deduplication
    /// - Parameters:
    ///   - data: The attachment data
    ///   - metadata: Attachment metadata
    /// - Returns: URL where the attachment was saved
    public func saveAttachment(data: Data, metadata: AttachmentMetadata) throws -> URL {
        logger.info("Saving attachment: \(metadata.filename) (\(data.count) bytes)")
        
        // Calculate checksum for deduplication
        let checksum = calculateSHA256(data)
        
        // Check if we already have this attachment (deduplication)
        if let existingURL = findExistingAttachment(checksum: checksum) {
            logger.info("Found existing attachment with same checksum: \(existingURL.path)")
            
            // Create symlink in target location to avoid duplication
            let targetURL = buildAttachmentURL(metadata: metadata)
            try createSymlinkIfNeeded(from: existingURL, to: targetURL)
            return targetURL
        }
        
        // Save new attachment
        let attachmentURL = try saveNewAttachment(data: data, metadata: metadata, checksum: checksum)
        
        // Update cache
        let cachedAttachment = CachedAttachment(data: data, metadata: metadata, url: attachmentURL)
        cacheQueue.async(flags: .barrier) {
            self.cache.setObject(cachedAttachment, 
                               forKey: metadata.cacheKey as NSString, 
                               cost: data.count)
        }
        
        logger.info("Attachment saved successfully: \(attachmentURL.path)")
        return attachmentURL
    }
    
    /// Get attachment URL if it exists
    /// - Parameters:
    ///   - accountId: Account ID
    ///   - mailId: Mail UID
    ///   - attachmentId: Attachment part ID
    /// - Returns: URL to attachment file or nil if not found
    public func getAttachment(accountId: UUID, mailId: String, attachmentId: String) -> URL? {
        let cacheKey = AttachmentMetadata.makeCacheKey(accountId: accountId, mailId: mailId, partId: attachmentId)
        
        // Check cache first
        if let cached = cacheQueue.sync(execute: { cache.object(forKey: cacheKey as NSString) }) {
            if fileManager.fileExists(atPath: cached.url.path) {
                return cached.url
            } else {
                // Remove stale cache entry
                cacheQueue.async(flags: .barrier) {
                    self.cache.removeObject(forKey: cacheKey as NSString)
                }
            }
        }
        
        // Build expected URL and check if file exists
        let expectedURL = buildAttachmentURL(accountId: accountId, mailId: mailId, attachmentId: attachmentId)
        
        if fileManager.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }
        
        logger.debug("Attachment not found: \(expectedURL.path)")
        return nil
    }
    
    /// Load attachment data from file system
    /// - Parameters:
    ///   - accountId: Account ID  
    ///   - mailId: Mail UID
    ///   - attachmentId: Attachment part ID
    /// - Returns: Attachment data or nil if not found
    public func loadAttachment(accountId: UUID, mailId: String, attachmentId: String) -> Data? {
        guard let url = getAttachment(accountId: accountId, mailId: mailId, attachmentId: attachmentId) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            logger.debug("Loaded attachment: \(url.lastPathComponent) (\(data.count) bytes)")
            return data
        } catch {
            logger.error("Failed to load attachment from \(url.path): \(error)")
            return nil
        }
    }
    
    /// Clean up old and orphaned attachments
    /// - Parameter policy: Cleanup policy to apply
    public func cleanupOldAttachments(policy: CleanupPolicy = .default) async {
        logger.info("Starting attachment cleanup with policy: maxAge=\(policy.maxAge)s, maxSize=\(policy.maxTotalSize) bytes")
        
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Remove attachments older than maxAge
            group.addTask {
                await self.cleanupByAge(maxAge: policy.maxAge)
            }
            
            // Task 2: Remove orphaned attachments (no corresponding database entries)
            group.addTask {
                await self.cleanupOrphanedAttachments(maxAge: policy.maxOrphanAge)
            }
            
            // Task 3: Enforce total size limit
            group.addTask {
                await self.enforceStorageLimit(maxSize: policy.maxTotalSize)
            }
        }
        
        // Clear cache after cleanup
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAllObjects()
        }
        
        logger.info("Attachment cleanup completed")
    }
    
    /// Get storage statistics
    public func getStorageStats() -> AttachmentStorageStats {
        var totalSize: Int64 = 0
        var fileCount = 0
        var accountCount = 0
        
        do {
            let accountDirs = try fileManager.contentsOfDirectory(at: baseDirectory, 
                                                                includingPropertiesForKeys: nil,
                                                                options: .skipsHiddenFiles)
            accountCount = accountDirs.count
            
            for accountDir in accountDirs {
                let enumerator = fileManager.enumerator(at: accountDir, 
                                                      includingPropertiesForKeys: [.fileSizeKey],
                                                      options: .skipsHiddenFiles)
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalSize += Int64(fileSize)
                        fileCount += 1
                    }
                }
            }
        } catch {
            logger.error("Failed to calculate storage stats: \(error)")
        }
        
        return AttachmentStorageStats(
            totalSize: totalSize,
            fileCount: fileCount,
            accountCount: accountCount,
            cacheCount: cache.countLimit
        )
    }
    
    // MARK: - Private Methods
    
    /// Save new attachment to file system
    private func saveNewAttachment(data: Data, metadata: AttachmentMetadata, checksum: String) throws -> URL {
        let attachmentURL = buildAttachmentURL(metadata: metadata)
        
        // Create directory structure
        try createDirectoryIfNeeded(attachmentURL.deletingLastPathComponent())
        
        // Write attachment data
        try data.write(to: attachmentURL)
        
        // Store checksum as extended attribute for deduplication
        try setExtendedAttribute(url: attachmentURL, key: "checksum", value: checksum)
        
        // Store original metadata as extended attributes
        try setExtendedAttribute(url: attachmentURL, key: "filename", value: metadata.filename)
        try setExtendedAttribute(url: attachmentURL, key: "mimeType", value: metadata.mimeType)
        try setExtendedAttribute(url: attachmentURL, key: "isInline", value: metadata.isInline ? "true" : "false")
        
        return attachmentURL
    }
    
    /// Build attachment URL for given metadata
    private func buildAttachmentURL(metadata: AttachmentMetadata) -> URL {
        return buildAttachmentURL(accountId: metadata.accountId, 
                                mailId: metadata.mailId, 
                                attachmentId: metadata.partId)
    }
    
    /// Build attachment URL for given parameters
    private func buildAttachmentURL(accountId: UUID, mailId: String, attachmentId: String) -> URL {
        return baseDirectory
            .appendingPathComponent(accountId.uuidString)
            .appendingPathComponent(mailId)
            .appendingPathComponent(attachmentId)
    }
    
    /// Find existing attachment with same checksum (for deduplication)
    private func findExistingAttachment(checksum: String) -> URL? {
        do {
            let enumerator = fileManager.enumerator(at: baseDirectory, 
                                                  includingPropertiesForKeys: nil,
                                                  options: .skipsHiddenFiles)
            
            while let fileURL = enumerator?.nextObject() as? URL {
                if let existingChecksum = getExtendedAttribute(url: fileURL, key: "checksum"),
                   existingChecksum == checksum {
                    return fileURL
                }
            }
        } catch {
            logger.error("Error searching for existing attachment: \(error)")
        }
        
        return nil
    }
    
    /// Create symlink to avoid file duplication
    private func createSymlinkIfNeeded(from sourceURL: URL, to targetURL: URL) throws {
        // Create target directory if needed
        try createDirectoryIfNeeded(targetURL.deletingLastPathComponent())
        
        // Remove existing file if present
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        
        // Create symlink
        try fileManager.createSymbolicLink(at: targetURL, withDestinationURL: sourceURL)
    }
    
    /// Create directory if it doesn't exist
    private func createDirectoryIfNeeded(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    /// Calculate SHA256 checksum for data
    private func calculateSHA256(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Set extended attribute on file
    private func setExtendedAttribute(url: URL, key: String, value: String) throws {
        let result = url.path.withCString { path in
            value.withCString { valuePtr in
                setxattr(path, key, valuePtr, value.utf8.count, 0, 0)
            }
        }
        
        if result != 0 {
            throw AttachmentError.extendedAttributeFailed("Failed to set \(key)")
        }
    }
    
    /// Get extended attribute from file
    private func getExtendedAttribute(url: URL, key: String) -> String? {
        let path = url.path
        
        // Get size of attribute
        let size = getxattr(path, key, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        
        // Allocate buffer and read attribute
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        
        let result = getxattr(path, key, buffer, size, 0, 0)
        guard result == size else { return nil }
        
        return String(cString: buffer)
    }
    
    /// Clean up attachments by age
    private func cleanupByAge(maxAge: TimeInterval) async {
        let cutoffDate = Date().addingTimeInterval(-maxAge)
        var removedCount = 0
        var removedSize: Int64 = 0
        
        do {
            let enumerator = fileManager.enumerator(at: baseDirectory, 
                                                  includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
                                                  options: .skipsHiddenFiles)
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                
                if let creationDate = resourceValues.creationDate,
                   creationDate < cutoffDate {
                    
                    if let fileSize = resourceValues.fileSize {
                        removedSize += Int64(fileSize)
                    }
                    
                    try fileManager.removeItem(at: fileURL)
                    removedCount += 1
                }
            }
        } catch {
            logger.error("Error during age-based cleanup: \(error)")
        }
        
        logger.info("Age-based cleanup completed: removed \(removedCount) files (\(removedSize) bytes)")
    }
    
    /// Clean up orphaned attachments
    private func cleanupOrphanedAttachments(maxAge: TimeInterval) async {
        // This would require integration with MailDAO to check which attachments
        // still have corresponding database entries
        logger.info("Orphaned attachment cleanup not yet implemented - requires MailDAO integration")
    }
    
    /// Enforce storage size limit by removing oldest files
    private func enforceStorageLimit(maxSize: Int64) async {
        var currentSize: Int64 = 0
        var files: [(url: URL, size: Int64, date: Date)] = []
        
        // Collect all files with their sizes and dates
        do {
            let enumerator = fileManager.enumerator(at: baseDirectory,
                                                  includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
                                                  options: .skipsHiddenFiles)
            
            while let fileURL = enumerator?.nextObject() as? URL {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                
                if let size = resourceValues.fileSize,
                   let date = resourceValues.creationDate {
                    files.append((url: fileURL, size: Int64(size), date: date))
                    currentSize += Int64(size)
                }
            }
        } catch {
            logger.error("Error collecting files for size enforcement: \(error)")
            return
        }
        
        // If we're under the limit, nothing to do
        guard currentSize > maxSize else {
            logger.info("Storage size (\(currentSize) bytes) is under limit (\(maxSize) bytes)")
            return
        }
        
        // Sort by date (oldest first) and remove until we're under the limit
        files.sort { $0.date < $1.date }
        
        var removedCount = 0
        var removedSize: Int64 = 0
        
        for file in files {
            guard currentSize > maxSize else { break }
            
            do {
                try fileManager.removeItem(at: file.url)
                currentSize -= file.size
                removedSize += file.size
                removedCount += 1
            } catch {
                logger.error("Failed to remove file \(file.url.path): \(error)")
            }
        }
        
        logger.info("Size enforcement cleanup completed: removed \(removedCount) files (\(removedSize) bytes)")
    }
}

// MARK: - Supporting Types

/// Attachment metadata for file operations
public struct AttachmentMetadata {
    public let accountId: UUID
    public let mailId: String
    public let partId: String
    public let filename: String
    public let mimeType: String
    public let isInline: Bool
    public let checksum: String?
    
    public init(accountId: UUID, mailId: String, partId: String, filename: String, 
                mimeType: String, isInline: Bool, checksum: String? = nil) {
        self.accountId = accountId
        self.mailId = mailId
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.isInline = isInline
        self.checksum = checksum
    }
    
    public var cacheKey: String {
        return Self.makeCacheKey(accountId: accountId, mailId: mailId, partId: partId)
    }
    
    public static func makeCacheKey(accountId: UUID, mailId: String, partId: String) -> String {
        return "\(accountId.uuidString):\(mailId):\(partId)"
    }
}

/// Cached attachment for in-memory storage
private class CachedAttachment {
    let data: Data
    let metadata: AttachmentMetadata
    let url: URL
    
    init(data: Data, metadata: AttachmentMetadata, url: URL) {
        self.data = data
        self.metadata = metadata
        self.url = url
    }
}

/// Storage statistics for monitoring
public struct AttachmentStorageStats {
    public let totalSize: Int64
    public let fileCount: Int
    public let accountCount: Int
    public let cacheCount: Int
    
    public var totalSizeMB: Double {
        return Double(totalSize) / (1024 * 1024)
    }
    
    public var averageFileSize: Int64 {
        return fileCount > 0 ? totalSize / Int64(fileCount) : 0
    }
}

/// Attachment-specific errors
public enum AttachmentError: LocalizedError {
    case extendedAttributeFailed(String)
    case fileNotFound(String)
    case insufficientSpace
    
    public var errorDescription: String? {
        switch self {
        case .extendedAttributeFailed(let message):
            return "Extended attribute operation failed: \(message)"
        case .fileNotFound(let path):
            return "Attachment file not found: \(path)"
        case .insufficientSpace:
            return "Insufficient storage space for attachment"
        }
    }
}