// AILO_APP/Services/Mail/MessageProcessingService.swift
// PHASE 3: Message Processing Orchestrator
// Integrates Phase 1 (Storage), Phase 2 (Fetching), Phase 3 (Parsing)

import Foundation

/// Orchestrates complete message processing pipeline
public class MessageProcessingService {
    
    private let blobStore: BlobStore
    private let writeDAO: MailWriteDAO
    private let readDAO: MailReadDAO
    private let mimeParser = EnhancedMIMEParser()
    private let contentParser = SimplifiedEmailContentParser()
    private let processor = StreamlinedBodyContentProcessor.self
    
    // MARK: - Initialization
    
    public init(blobStore: BlobStore, writeDAO: MailWriteDAO, readDAO: MailReadDAO) {
        self.blobStore = blobStore
        self.writeDAO = writeDAO
        self.readDAO = readDAO
    }
    
    // MARK: - Main Processing Pipeline
    
    /// Process complete message (Phase 1 + 2 + 3 integration)
    /// This is the main entry point for message processing
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - accountId: Account UUID
    ///   - folder: Folder name
    ///   - uid: IMAP UID
    ///   - structure: BODYSTRUCTURE from Phase 2
    ///   - sectionContents: Fetched section contents from Phase 2
    /// - Returns: Processing summary
    public func processMessage(
        messageId: UUID,
        accountId: UUID,
        folder: String,
        uid: String,
        structure: EnhancedBodyStructure,
        sectionContents: [String: Data]
    ) async throws -> ProcessingSummary {
        
        print("🔄 [MessageProcessing] Starting pipeline for message \(messageId)")
        
        var summary = ProcessingSummary(messageId: messageId)
        
        // STEP 1: Check if already processed (render cache exists)
        if try readDAO.hasValidRenderCache(messageId: messageId, requiredVersion: 1) {
            print("✅ [MessageProcessing] Message already processed (cache hit)")
            summary.cacheHit = true
            return summary
        }
        
        // STEP 2: Parse MIME (single pass)
        let parseResult = mimeParser.parseWithStructure(
            structure: structure,
            sectionContents: sectionContents,
            defaultCharset: "utf-8"
        )
        
        summary.partsProcessed = parseResult.parts.count
        summary.attachmentsFound = parseResult.attachments.count
        
        print("📊 [MessageProcessing] Parsed: \(parseResult.parts.count) parts, \(parseResult.attachments.count) attachments")
        
        // STEP 3: Store MIME parts (Phase 1)
        let mimePartEntities = parseResult.toMimePartEntities(messageId: messageId)
        try writeDAO.storeMimeParts(messageId: messageId, parts: mimePartEntities)
        
        print("💾 [MessageProcessing] Stored \(mimePartEntities.count) MIME parts")
        
        // STEP 4: Store attachments in blob store (Phase 1)
        for attachment in parseResult.attachments {
            // Store blob
            let blobId = try blobStore.store(attachment.content)
            
            // Register in DB
            let storagePath = "\(blobId.prefix(2))/\(blobId.dropFirst(2).prefix(2))/\(blobId)"
            try writeDAO.registerBlob(
                blobId: blobId,
                storagePath: storagePath,
                sizeBytes: attachment.content.count
            )
            
            summary.bytesStored += attachment.content.count
        }
        
        print("💾 [MessageProcessing] Stored \(parseResult.attachments.count) attachments (\(summary.bytesStored) bytes)")
        
        // STEP 5: Finalize body content (Phase 3)
        var finalHTML: String?
        var finalText: String?
        
        if let body = parseResult.bestBodyCandidate {
            switch body.contentType {
            case .html:
                finalHTML = processor.finalizeHTMLForDisplay(
                    body.content,
                    inlineRefs: parseResult.inlineReferences,
                    messageId: messageId
                )
                
            case .plain:
                finalText = processor.finalizeTextForDisplay(body.content)
            }
        }
        
        // STEP 6: Store render cache (Phase 1)
        try writeDAO.storeRenderCache(
            messageId: messageId,
            htmlRendered: finalHTML,
            textRendered: finalText,
            generatorVersion: 1
        )
        
        summary.cacheGenerated = true
        
        print("✅ [MessageProcessing] Pipeline complete")
        print("   - Cache: \(finalHTML != nil ? "HTML" : finalText != nil ? "Text" : "none")")
        print("   - Attachments: \(summary.attachmentsFound)")
        print("   - Storage: \(summary.bytesStored) bytes")
        
        return summary
    }
    
    // MARK: - Cache Retrieval
    
    /// Get processed message content (from cache if available)
    /// - Parameter messageId: Message UUID
    /// - Returns: Processed message ready for display
    public func getProcessedMessage(messageId: UUID) throws -> ProcessedMessage? {
        // Try render cache first (fast path)
        if let cache = try readDAO.getRenderCache(messageId: messageId) {
            return ProcessedMessage(
                messageId: messageId,
                htmlContent: cache.htmlRendered,
                textContent: cache.textRendered,
                fromCache: true
            )
        }
        
        // No cache - needs processing
        return nil
    }
    
    // MARK: - Attachment Retrieval
    
    /// Get attachment content by part ID
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - partId: Part ID (section ID)
    /// - Returns: Attachment data
    public func getAttachmentContent(messageId: UUID, partId: String) throws -> Data? {
        // Get MIME part
        let parts = try readDAO.getMimeParts(messageId: messageId)
        guard let part = parts.first(where: { $0.partId == partId }),
              let blobId = part.blobId else {
            return nil
        }
        
        // Retrieve from blob store
        return try blobStore.retrieve(blobId)
    }
    
    /// Get inline content by content ID (for cid: resolution)
    /// - Parameters:
    ///   - messageId: Message UUID
    ///   - contentId: Content-ID value
    /// - Returns: Inline content data and media type
    public func getInlineContent(messageId: UUID, contentId: String) throws -> (data: Data, mediaType: String)? {
        // Get MIME part by content ID
        guard let part = try readDAO.getMimePartByContentId(messageId: messageId, contentId: contentId),
              let blobId = part.blobId else {
            return nil
        }
        
        // Retrieve from blob store
        guard let data = try blobStore.retrieve(blobId) else {
            return nil
        }
        
        return (data, part.mediaType)
    }
    
    // MARK: - Batch Processing
    
    /// Process multiple messages in batch
    /// - Parameters:
    ///   - messages: Array of message info tuples
    ///   - concurrency: Maximum concurrent operations
    /// - Returns: Array of processing summaries
    public func processMessagesBatch(
        messages: [(messageId: UUID, accountId: UUID, folder: String, uid: String,
                   structure: EnhancedBodyStructure, sectionContents: [String: Data])],
        concurrency: Int = 3
    ) async throws -> [ProcessingSummary] {
        
        print("🔄 [MessageProcessing] Batch processing \(messages.count) messages (concurrency: \(concurrency))")
        
        var summaries: [ProcessingSummary] = []
        
        // Process in batches to avoid overwhelming system
        for batch in messages.chunked(into: concurrency) {
            let batchResults = try await withThrowingTaskGroup(of: ProcessingSummary.self) { group in
                for message in batch {
                    group.addTask {
                        try await self.processMessage(
                            messageId: message.messageId,
                            accountId: message.accountId,
                            folder: message.folder,
                            uid: message.uid,
                            structure: message.structure,
                            sectionContents: message.sectionContents
                        )
                    }
                }
                
                var results: [ProcessingSummary] = []
                for try await result in group {
                    results.append(result)
                }
                return results
            }
            
            summaries.append(contentsOf: batchResults)
        }
        
        print("✅ [MessageProcessing] Batch complete: \(summaries.count) messages processed")
        
        return summaries
    }
}

// MARK: - Supporting Types

/// Summary of message processing
public struct ProcessingSummary: Sendable {
    public let messageId: UUID
    public var partsProcessed: Int = 0
    public var attachmentsFound: Int = 0
    public var bytesStored: Int = 0
    public var cacheGenerated: Bool = false
    public var cacheHit: Bool = false
    public var duration: TimeInterval = 0
    
    public init(messageId: UUID) {
        self.messageId = messageId
    }
}

/// Processed message ready for display
public struct ProcessedMessage: Sendable {
    public let messageId: UUID
    public let htmlContent: String?
    public let textContent: String?
    public let fromCache: Bool
    
    public init(messageId: UUID, htmlContent: String?, textContent: String?, fromCache: Bool) {
        self.messageId = messageId
        self.htmlContent = htmlContent
        self.textContent = textContent
        self.fromCache = fromCache
    }
}

// MARK: - Array Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Usage Documentation

/*
 MESSAGE PROCESSING SERVICE USAGE
 =================================
 
 PHASE 1 + 2 + 3 INTEGRATION:
 
 // Initialize service
 let blobStore = try BlobStore()
 let service = MessageProcessingService(
     blobStore: blobStore,
     writeDAO: writeDAO,
     readDAO: readDAO
 )
 
 // Process message (after Phase 2 fetch)
 let summary = try await service.processMessage(
     messageId: messageId,
     accountId: accountId,
     folder: folder,
     uid: uid,
     structure: enhancedStructure,      // From Phase 2
     sectionContents: sectionContents   // From Phase 2
 )
 
 print("Processed: \(summary.partsProcessed) parts")
 
 // Display message (instant if cached)
 if let message = try service.getProcessedMessage(messageId: messageId) {
     if message.fromCache {
         print("✅ Cache hit - instant display")
     }
     
     if let html = message.htmlContent {
         webView.loadHTMLString(html, baseURL: nil)
     } else if let text = message.textContent {
         textView.text = text
     }
 }
 
 // Get inline image (for cid: URL handler)
 if let (data, type) = try service.getInlineContent(
     messageId: messageId,
     contentId: "image123"
 ) {
     // Serve to WebView
 }
 */
