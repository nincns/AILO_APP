// AttachmentDownloadController.swift
// Controller für On-Demand Attachment Downloads

import Foundation

// MARK: - Attachment Download Controller

class AttachmentDownloadController {
    
    private let blobStore: BlobStoreProtocol
    private let imapClient: IMAPClient
    private let securityService: AttachmentSecurityService
    private let writeDAO: MailWriteDAO
    
    private var downloadQueue = DispatchQueue(label: "attachment.download", qos: .background)
    private var activeDownloads = Set<String>()
    
    init(blobStore: BlobStoreProtocol,
         imapClient: IMAPClient,
         securityService: AttachmentSecurityService,
         writeDAO: MailWriteDAO) {
        self.blobStore = blobStore
        self.imapClient = imapClient
        self.securityService = securityService
        self.writeDAO = writeDAO
    }
    
    // MARK: - Download Attachment
    
    func downloadAttachment(messageId: UUID,
                           partId: String,
                           section: String,
                           expectedSize: Int) async throws -> Data {
        
        let downloadKey = "\(messageId)-\(partId)"
        
        // Check if already downloading
        if activeDownloads.contains(downloadKey) {
            throw AttachmentError.alreadyDownloading
        }
        
        activeDownloads.insert(downloadKey)
        defer { activeDownloads.remove(downloadKey) }
        
        // Check blob store first
        if let existingBlobId = try getBlobId(messageId: messageId, partId: partId),
           let data = try blobStore.retrieve(blobId: existingBlobId) {
            print("✅ Attachment found in blob store: \(existingBlobId)")
            return data
        }
        
        // Download from server
        print("📥 Downloading attachment: \(section) (\(expectedSize) bytes)")
        
        let data: Data
        
        if expectedSize > 1024 * 1024 { // > 1MB
            // Use partial fetch for large attachments
            data = try await downloadPartial(section: section, totalSize: expectedSize)
        } else {
            // Single fetch for small attachments
            data = try await imapClient.fetchSection(section: section)
        }
        
        // Security scan
        try await securityService.scanAttachment(data)
        
        // Store in blob store
        let blobId = try blobStore.store(data, messageId: messageId, partId: partId)
        
        // Update database
        try updateBlobReference(messageId: messageId, partId: partId, blobId: blobId)
        
        return data
    }
    
    // MARK: - Partial Download
    
    private func downloadPartial(section: String, totalSize: Int) async throws -> Data {
        var fullData = Data()
        let chunkSize = 512 * 1024 // 512KB chunks
        var offset = 0
        
        while offset < totalSize {
            let length = min(chunkSize, totalSize - offset)
            
            print("📊 Downloading chunk: \(offset)-\(offset + length) of \(totalSize)")
            
            let chunk = try await imapClient.fetchPartial(
                section: section,
                offset: offset,
                length: length
            )
            
            fullData.append(chunk)
            offset += length
            
            // Progress callback if needed
            notifyProgress(offset, totalSize)
        }
        
        return fullData
    }
    
    // MARK: - Database Operations
    
    private func getBlobId(messageId: UUID, partId: String) throws -> String? {
        // Query mime_parts for existing blob_id
        return nil // Placeholder
    }
    
    private func updateBlobReference(messageId: UUID, partId: String, blobId: String) throws {
        // Update mime_parts with new blob_id
    }
    
    // MARK: - Progress Notification
    
    private func notifyProgress(_ current: Int, _ total: Int) {
        let progress = Float(current) / Float(total)
        NotificationCenter.default.post(
            name: .attachmentDownloadProgress,
            object: nil,
            userInfo: ["progress": progress]
        )
    }
}

// MARK: - Batch Download

extension AttachmentDownloadController {
    
    func downloadAllAttachments(for messageId: UUID) async throws {
        // Get all attachment parts
        let parts = try getAttachmentParts(messageId: messageId)
        
        // Download in parallel with concurrency limit
        await withTaskGroup(of: Void.self) { group in
            for part in parts {
                group.addTask {
                    try? await self.downloadAttachment(
                        messageId: messageId,
                        partId: part.partId,
                        section: part.section,
                        expectedSize: part.size
                    )
                }
            }
        }
    }
    
    private func getAttachmentParts(messageId: UUID) throws -> [(partId: String, section: String, size: Int)] {
        // Query mime_parts for attachment parts
        return [] // Placeholder
    }
}

enum AttachmentError: Error {
    case alreadyDownloading
    case downloadFailed
    case securityCheckFailed
}

extension Notification.Name {
    static let attachmentDownloadProgress = Notification.Name("attachmentDownloadProgress")
}
