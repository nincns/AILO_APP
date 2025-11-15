// MessageProcessingService.swift
// Orchestrierung der kompletten Nachrichtenverarbeitung

import Foundation

// MARK: - Message Processing Service

class MessageProcessingService {
    
    private let blobStore: BlobStoreProtocol
    private let renderCache: RenderCacheDAO
    private let writeDAO: MailWriteDAO
    private let readDAO: MailReadDAO
    private let mimeParser: MIMEParser
    private let bodyProcessor: BodyContentProcessor
    private let fetchStrategy: FetchStrategy
    
    init(blobStore: BlobStoreProtocol,
         renderCache: RenderCacheDAO,
         writeDAO: MailWriteDAO,
         readDAO: MailReadDAO) {
        self.blobStore = blobStore
        self.renderCache = renderCache
        self.writeDAO = writeDAO
        self.readDAO = readDAO
        self.mimeParser = MIMEParser()
        self.bodyProcessor = BodyContentProcessor()
        self.fetchStrategy = FetchStrategy()
    }
    
    // MARK: - Main Processing Pipeline
    
    func processMessage(messageId: UUID,
                       accountId: UUID,
                       folder: String,
                       uid: String,
                       rawMessage: Data?,
                       bodyStructure: IMAPBodyStructure?) async throws {
        
        print("📧 [MessageProcessing] Starting for message \(messageId)")
        
        // Step 1: Store RAW message if available
        if let raw = rawMessage {
            let blobId = try blobStore.storeRawMessage(raw, messageId: messageId)
            try writeDAO.updateRawBlobId(messageId: messageId, blobId: blobId)
            print("✅ Stored RAW message: \(blobId)")
        }
        
        // Step 2: Create fetch plan from BODYSTRUCTURE
        let fetchPlan = bodyStructure != nil ? fetchStrategy.createFetchPlan(from: bodyStructure!) : nil
        
        // Step 3: Parse MIME structure (single-pass)
        let mimeParts = try parseMimeStructure(messageId: messageId,
                                              rawMessage: rawMessage,
                                              bodyStructure: bodyStructure)
        
        // Step 4: Store MIME parts metadata
        try storeMimeParts(messageId: messageId, parts: mimeParts)
        
        // Step 5: Process and store body parts
        let bodyContent = try processBodyParts(messageId: messageId,
                                              parts: mimeParts,
                                              fetchPlan: fetchPlan)
        
        // Step 6: Store attachments
        try processAttachments(messageId: messageId,
                              accountId: accountId,
                              folder: folder,
                              uid: uid,
                              parts: mimeParts)
        
        // Step 7: Finalize HTML with CID rewriting
        let finalizedContent = try finalizeContent(messageId: messageId,
                                                  content: bodyContent,
                                                  parts: mimeParts)
        
        // Step 8: Store in render cache
        try storeRenderCache(messageId: messageId, content: finalizedContent)
        
        print("✅ [MessageProcessing] Completed for message \(messageId)")
    }
    
    // MARK: - MIME Parsing
    
    private func parseMimeStructure(messageId: UUID,
                                   rawMessage: Data?,
                                   bodyStructure: IMAPBodyStructure?) throws -> [MimePartEntity] {
        
        var parts: [MimePartEntity] = []
        
        if let structure = bodyStructure {
            // Use BODYSTRUCTURE for metadata
            parts = convertBodyStructureToMimeParts(structure, messageId: messageId)
        } else if let raw = rawMessage {
            // Fallback to parsing RAW message
            parts = try mimeParser.parse(raw, messageId: messageId)
        }
        
        return parts
    }
    
    private func convertBodyStructureToMimeParts(_ structure: IMAPBodyStructure,
                                                messageId: UUID) -> [MimePartEntity] {
        var parts: [MimePartEntity] = []
        
        func traverse(_ part: IMAPBodyPart, partId: String, parentId: String?) {
            let entity = MimePartEntity(
                id: UUID(),
                messageId: messageId,
                partId: partId,
                parentPartId: parentId,
                mediaType: part.mediaType,
                charset: part.charset,
                transferEncoding: part.encoding,
                disposition: part.disposition,
                filenameOriginal: part.filename,
                filenameNormalized: normalizeFilename(part.filename),
                contentId: part.contentId,
                sizeOctets: part.size ?? 0,
                isBodyCandidate: isBodyCandidate(part)
            )
            parts.append(entity)
            
            // Traverse subparts
            if case .multipart(_, let subparts) = part.type {
                for (index, subpart) in subparts.enumerated() {
                    let subPartId = "\(partId).\(index + 1)"
                    traverse(subpart, partId: subPartId, parentId: partId)
                }
            }
        }
        
        traverse(structure.rootPart, partId: "1", parentId: nil)
        return parts
    }
    
    // MARK: - Body Processing
    
    private func processBodyParts(messageId: UUID,
                                 parts: [MimePartEntity],
                                 fetchPlan: FetchPlan?) throws -> ProcessedContent {
        
        // Find body candidates
        let bodyCandidates = parts.filter { $0.isBodyCandidate }
        
        // Select best body part
        let selectedBody = selectBestBodyPart(from: bodyCandidates)
        
        guard let bodyPart = selectedBody else {
            return ProcessedContent(html: nil, text: nil)
        }
        
        // Get content for the selected part
        let content = try retrievePartContent(bodyPart)
        
        // Process content
        return bodyProcessor.process(content,
                                    mimeType: bodyPart.mediaType,
                                    charset: bodyPart.charset)
    }
    
    private func selectBestBodyPart(from candidates: [MimePartEntity]) -> MimePartEntity? {
        // Prefer HTML over plain text
        if let html = candidates.first(where: { $0.mediaType.contains("html") }) {
            return html
        }
        return candidates.first(where: { $0.mediaType.contains("plain") })
    }
    
    // MARK: - Attachment Processing
    
    private func processAttachments(messageId: UUID,
                                   accountId: UUID,
                                   folder: String,
                                   uid: String,
                                   parts: [MimePartEntity]) throws {
        
        let attachmentParts = parts.filter {
            $0.disposition?.lowercased() == "attachment" ||
            (!$0.isBodyCandidate && $0.filenameOriginal != nil)
        }
        
        for part in attachmentParts {
            // Store attachment metadata
            let attachment = AttachmentEntity(
                partId: part.partId,
                filename: part.filenameNormalized ?? "unnamed",
                mimeType: part.mediaType,
                sizeBytes: part.sizeOctets,
                data: nil,  // Data stored in blob store
                contentId: part.contentId,
                isInline: part.contentId != nil,
                checksum: part.contentSha256
            )
            
            try writeDAO.storeAttachment(accountId: accountId,
                                        folder: folder,
                                        uid: uid,
                                        attachment: attachment)
        }
    }
    
    // MARK: - Content Finalization
    
    private func finalizeContent(messageId: UUID,
                                content: ProcessedContent,
                                parts: [MimePartEntity]) throws -> FinalizedContent {
        
        var finalHtml = content.html
        
        // Rewrite CID references
        if let html = finalHtml {
            finalHtml = rewriteCidReferences(html: html,
                                            messageId: messageId,
                                            parts: parts)
        }
        
        // Sanitize HTML
        if let html = finalHtml {
            finalHtml = sanitizeHtml(html)
        }
        
        return FinalizedContent(
            html: finalHtml,
            text: content.text,
            generatorVersion: 1
        )
    }
    
    private func rewriteCidReferences(html: String,
                                     messageId: UUID,
                                     parts: [MimePartEntity]) -> String {
        var result = html
        
        // Find all cid: references
        let pattern = #"cid:([^"\s]+)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        
        // Replace from end to beginning to maintain string indices
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: html) {
                let contentId = String(html[range])
                
                // Find part with this content-id
                if let part = parts.first(where: { $0.contentId == contentId }) {
                    let newUrl = "/mail/\(messageId)/cid/\(contentId)"
                    let fullRange = Range(match.range, in: html)!
                    result.replaceSubrange(fullRange, with: newUrl)
                }
            }
        }
        
        return result
    }
    
    private func sanitizeHtml(_ html: String) -> String {
        // Basic HTML sanitization
        var sanitized = html
        
        // Remove script tags
        sanitized = sanitized.replacingOccurrences(
            of: #"<script[^>]*>.*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove dangerous attributes
        let dangerousAttrs = ["onclick", "onload", "onerror", "onmouseover"]
        for attr in dangerousAttrs {
            sanitized = sanitized.replacingOccurrences(
                of: #"\s*\#(attr)="[^"]*""#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        return sanitized
    }
    
    // MARK: - Storage Operations
    
    private func storeMimeParts(messageId: UUID, parts: [MimePartEntity]) throws {
        try writeDAO.storeMimeParts(messageId: messageId, parts: parts)
    }
    
    private func storeRenderCache(messageId: UUID, content: FinalizedContent) throws {
        try renderCache.store(
            messageId: messageId,
            html: content.html,
            text: content.text,
            generatorVersion: content.generatorVersion
        )
    }
    
    private func retrievePartContent(_ part: MimePartEntity) throws -> Data {
        if let blobId = part.blobId,
           let data = try blobStore.retrieve(blobId: blobId) {
            return data
        }
        
        // Fallback: fetch from server if needed
        throw MessageProcessingError.contentNotAvailable(partId: part.partId)
    }
    
    // MARK: - Helper Functions
    
    private func normalizeFilename(_ filename: String?) -> String? {
        guard let name = filename else { return nil }
        
        // Remove path components
        let normalized = (name as NSString).lastPathComponent
        
        // Replace problematic characters
        return normalized
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
    
    private func isBodyCandidate(_ part: IMAPBodyPart) -> Bool {
        switch part.type {
        case .text(let subtype, _):
            return subtype == "plain" || subtype == "html"
        default:
            return false
        }
    }
}


