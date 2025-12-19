// AILO_APP/Storage/BlobStore_Phase6_Security.swift
// PHASE 6: BlobStore Security Extensions
// Adds scan status tracking, quarantine management, and secure access

import Foundation
import CryptoKit

// MARK: - BlobStore Security Extensions

extension BlobStore {
    
    // MARK: - Quarantine Management
    
    /// Move blob to quarantine storage
    func quarantineBlob(hash: String, reason: String) throws {
        print("🔒 [BLOBSTORE] Quarantining blob \(hash.prefix(8))...")
        
        // Get original blob
        guard let data = try retrieve(hash: hash) else {
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
        
        return try retrieve(hash: hash)
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

// MARK: - Usage Documentation

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
