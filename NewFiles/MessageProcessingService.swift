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
            // Fallback to parsing RAW message using parseSinglePass
            let parsedMessage = try mimeParser.parseSinglePass(raw, messageId: messageId)
            // Convert MIMEParser.MimePartEntity to our MimePartEntity
            parts = parsedMessage.mimeParts.map { parserPart in
                MimePartEntity(
                    id: UUID(),
                    messageId: messageId,
                    partNumber: parserPart.partId,
                    contentType: parserPart.contentType,
                    contentSubtype: nil,
                    contentId: parserPart.contentId,
                    contentDisposition: parserPart.disposition,
                    filename: parserPart.filenameOriginal,
                    size: Int64(parserPart.size),
                    encoding: parserPart.encoding,
                    charset: parserPart.charset,
                    isAttachment: parserPart.disposition?.lowercased() == "attachment",
                    isInline: parserPart.contentId != nil,
                    parentPartNumber: nil,
                    partId: parserPart.partId,
                    parentPartId: nil,
                    mediaType: parserPart.contentType,
                    transferEncoding: parserPart.encoding,
                    filenameOriginal: parserPart.filenameOriginal,
                    filenameNormalized: parserPart.filenameOriginal,
                    sizeOctets: Int64(parserPart.size),
                    isBodyCandidate: parserPart.isBodyCandidate,
                    blobId: nil
                )
            }
        }

        return parts
    }
    
    private func convertBodyStructureToMimeParts(_ structure: IMAPBodyStructure,
                                                messageId: UUID) -> [MimePartEntity] {
        var parts: [MimePartEntity] = []

        func traverse(_ part: IMAPBodyStructure, partId: String, parentId: String?) {
            let (mediaType, charset, isBody, subparts) = extractPartInfo(part)

            let entity = MimePartEntity(
                id: UUID(),
                messageId: messageId,
                partNumber: partId,
                contentType: mediaType,
                contentSubtype: nil,
                contentId: nil,
                contentDisposition: nil,
                filename: nil,
                size: 0,
                encoding: nil,
                charset: charset,
                isAttachment: !isBody,
                isInline: false,
                parentPartNumber: parentId,
                partId: partId,
                parentPartId: parentId,
                mediaType: mediaType,
                transferEncoding: nil,
                filenameOriginal: nil,
                filenameNormalized: nil,
                sizeOctets: 0,
                isBodyCandidate: isBody,
                blobId: nil
            )
            parts.append(entity)

            // Traverse subparts for multipart
            for (index, subpart) in subparts.enumerated() {
                let subPartId = "\(partId).\(index + 1)"
                traverse(subpart, partId: subPartId, parentId: partId)
            }
        }

        traverse(structure, partId: "1", parentId: nil)
        return parts
    }

    private func extractPartInfo(_ part: IMAPBodyStructure) -> (mediaType: String, charset: String?, isBody: Bool, subparts: [IMAPBodyStructure]) {
        switch part {
        case .text(let subtype, let charset):
            return ("text/\(subtype)", charset, subtype == "plain" || subtype == "html", [])
        case .multipart(let subtype, let parts):
            return ("multipart/\(subtype)", nil, false, parts)
        case .image(let subtype):
            return ("image/\(subtype)", nil, false, [])
        case .application(let subtype):
            return ("application/\(subtype)", nil, false, [])
        case .message(let subtype):
            return ("message/\(subtype)", nil, false, [])
        case .audio(let subtype):
            return ("audio/\(subtype)", nil, false, [])
        case .video(let subtype):
            return ("video/\(subtype)", nil, false, [])
        case .other(let type, let subtype):
            return ("\(type)/\(subtype)", nil, false, [])
        }
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

        // Decode content to string
        let charset = bodyPart.charset ?? "utf-8"
        let encoding: String.Encoding = charset.lowercased() == "utf-8" ? .utf8 :
                                         charset.lowercased() == "iso-8859-1" ? .isoLatin1 :
                                         charset.lowercased() == "windows-1252" ? .windowsCP1252 : .utf8
        let decodedString = String(data: content, encoding: encoding) ?? String(data: content, encoding: .utf8) ?? ""

        // Process content using static methods from BodyContentProcessor
        if bodyPart.mediaType.lowercased().contains("html") {
            let cleanedHtml = BodyContentProcessor.cleanHTMLForDisplay(decodedString)
            return ProcessedContent(html: cleanedHtml, text: nil)
        } else {
            let cleanedText = BodyContentProcessor.cleanPlainTextForDisplay(decodedString)
            return ProcessedContent(html: nil, text: cleanedText)
        }
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
            // Store attachment metadata using correct initializer
            let attachment = AttachmentEntity(
                accountId: accountId,
                folder: folder,
                uid: uid,
                partId: part.partId,
                filename: part.filenameNormalized ?? "unnamed",
                mimeType: part.mediaType,
                sizeBytes: Int(part.sizeOctets),  // Convert Int64 to Int
                data: nil,  // Data stored in blob store
                contentId: part.contentId,
                isInline: part.contentId != nil,
                filePath: nil,
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
        // The MailWriteDAO protocol expects just the parts array
        try writeDAO.storeMimeParts(parts)
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
    
}


