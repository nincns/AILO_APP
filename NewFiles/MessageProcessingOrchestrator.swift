// AILO_APP/Services/Integration/MessageProcessingOrchestrator_Phase8.swift
// PHASE 8: Message Processing Orchestrator
// Complete integration of all phases: IMAP → Parse → Security → Render → Serve

import Foundation

// MARK: - Processing Status

public enum ProcessingStatus: String, Sendable {
    case pending = "pending"
    case fetching = "fetching"
    case parsing = "parsing"
    case scanning = "scanning"
    case rendering = "rendering"
    case completed = "completed"
    case failed = "failed"
    case partialSuccess = "partial_success"
}

// MARK: - Processing Result

public struct MessageProcessingResult: Sendable {
    public let messageId: UUID
    public let status: ProcessingStatus
    public let bodyHTML: String?
    public let bodyText: String?
    public let attachmentCount: Int
    public let securePartsCount: Int
    public let processingTime: TimeInterval
    public let fromCache: Bool
    public let errors: [String]
    public let warnings: [String]
    
    public init(
        messageId: UUID,
        status: ProcessingStatus,
        bodyHTML: String?,
        bodyText: String?,
        attachmentCount: Int,
        securePartsCount: Int,
        processingTime: TimeInterval,
        fromCache: Bool,
        errors: [String] = [],
        warnings: [String] = []
    ) {
        self.messageId = messageId
        self.status = status
        self.bodyHTML = bodyHTML
        self.bodyText = bodyText
        self.attachmentCount = attachmentCount
        self.securePartsCount = securePartsCount
        self.processingTime = processingTime
        self.fromCache = fromCache
        self.errors = errors
        self.warnings = warnings
    }
}

// MARK: - Message Processing Orchestrator

public actor MessageProcessingOrchestrator {
    
    // Phase dependencies
    private let blobStore: BlobStore
    private let database: OpaquePointer
    private let securityService: AttachmentSecurityService
    private let servingService: AttachmentServingService
    private let limitsService: MessageLimitsService
    
    public init(
        blobStore: BlobStore,
        database: OpaquePointer,
        securityService: AttachmentSecurityService,
        servingService: AttachmentServingService,
        limitsService: MessageLimitsService
    ) {
        self.blobStore = blobStore
        self.database = database
        self.securityService = securityService
        self.servingService = servingService
        self.limitsService = limitsService
    }
    
    // MARK: - Complete Processing Pipeline
    
    public func processMessage(
        accountId: UUID,
        folder: String,
        uid: String,
        rawRFC822: String
    ) async throws -> MessageProcessingResult {
        
        let startTime = Date()
        let messageId = UUID()
        var errors: [String] = []
        var warnings: [String] = []
        
        print("🔄 [ORCHESTRATOR] Starting complete processing for \(uid)")
        
        // Step 1: Check render cache
        if let cached = try await checkRenderCache(messageId: messageId) {
            print("⚡️ [ORCHESTRATOR] Served from cache")
            return cached
        }
        
        // Step 2: Size check
        let rawSize = rawRFC822.utf8.count
        let sizeCheck = await limitsService.checkMessageSize(serverReportedSize: rawSize)
        if case .exceeded(let msg, _, _) = sizeCheck {
            throw NSError(domain: "Orchestrator", code: 8001,
                         userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if case .warning(let msg, _) = sizeCheck {
            warnings.append(msg)
        }
        
        // Step 3: Store RAW
        let rawBlobId = try storeRawMessage(raw: rawRFC822)
        
        // Step 4: Parse MIME
        let (headers, body) = TechnicalHeaderParser.parse(rawMessage: rawRFC822)
        let mimeParts = try parseMIME(rawContent: body, headers: headers)
        
        // Step 5: Detect secure parts (S/MIME, PGP)
        let secureParts = SecureMailPartHandler.detectSecureParts(in: mimeParts)
        if secureParts.hasSecureParts {
            warnings.append("Message contains \(secureParts.secureParts.count) secure parts")
        }
        
        // Step 6: Select best body
        let bodySelection = selectBestBody(from: mimeParts)
        
        // Step 7: Process attachments
        let attachmentResults = try await processAttachments(
            mimeParts: mimeParts,
            messageId: messageId
        )
        
        if !attachmentResults.errors.isEmpty {
            errors.append(contentsOf: attachmentResults.errors)
        }
        if !attachmentResults.warnings.isEmpty {
            warnings.append(contentsOf: attachmentResults.warnings)
        }
        
        // Step 8: Finalize HTML (CID rewrite)
        let finalHTML = finalizeHTML(
            html: bodySelection.selectedPart.content,
            messageId: messageId,
            inlineAttachments: bodySelection.inlineAttachments
        )
        
        // Step 9: Store in render cache
        try storeRenderCache(
            messageId: messageId,
            html: finalHTML,
            text: bodySelection.selectedPart.mediaType.contains("plain") ? bodySelection.selectedPart.content : nil
        )
        
        // Step 10: Store message metadata
        try storeMessageMetadata(
            messageId: messageId,
            accountId: accountId,
            folder: folder,
            uid: uid,
            rawBlobId: rawBlobId,
            headers: headers,
            hasAttachments: attachmentResults.attachments.count > 0
        )
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        print("✅ [ORCHESTRATOR] Processing complete in \(String(format: "%.2f", processingTime))s")
        
        return MessageProcessingResult(
            messageId: messageId,
            status: errors.isEmpty ? .completed : .partialSuccess,
            bodyHTML: finalHTML,
            bodyText: bodySelection.selectedPart.content,
            attachmentCount: attachmentResults.attachments.count,
            securePartsCount: secureParts.secureParts.count,
            processingTime: processingTime,
            fromCache: false,
            errors: errors,
            warnings: warnings
        )
    }
    
    // MARK: - Step: Check Render Cache
    
    private func checkRenderCache(messageId: UUID) async throws -> MessageProcessingResult? {
        let sql = "SELECT html_rendered, text_rendered, generated_at FROM render_cache WHERE message_id = ?"
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, (messageId.uuidString as NSString).utf8String, -1, nil)
        
        var result: MessageProcessingResult?
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let html = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            
            result = MessageProcessingResult(
                messageId: messageId,
                status: .completed,
                bodyHTML: html,
                bodyText: text,
                attachmentCount: 0,
                securePartsCount: 0,
                processingTime: 0,
                fromCache: true
            )
        }
        
        sqlite3_finalize(statement)
        return result
    }
    
    // MARK: - Step: Store RAW
    
    private func storeRawMessage(raw: String) throws -> String {
        let data = Data(raw.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        try blobStore.store(data: data, hash: hash)
        return hash
    }
    
    // MARK: - Step: Parse MIME
    
    private func parseMIME(rawContent: String, headers: [EmailHeader]) throws -> [MIMEPart] {
        // Extract Content-Type header
        let contentTypeHeader = headers.first { $0.name.lowercased() == "content-type" }
        let contentType = contentTypeHeader?.value ?? "text/plain"
        
        // Check if multipart
        if contentType.lowercased().contains("multipart") {
            let boundary = MIMEParser.extractBoundary(from: contentType)
            if let boundary = boundary {
                return MIMEParser.parseMultipart(content: rawContent, boundary: boundary)
            }
        }
        
        // Single part
        let headerDict = Dictionary(uniqueKeysWithValues: headers.map { ($0.name.lowercased(), $0.value) })
        
        return [MIMEPart(
            partId: "1",
            headers: headerDict,
            body: rawContent,
            mediaType: contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "text/plain",
            charset: MIMEParser.extractCharset(from: contentType),
            transferEncoding: headerDict["content-transfer-encoding"],
            disposition: headerDict["content-disposition"],
            filename: MIMEParser.decodeInternationalFilename(from: headerDict),
            contentId: MIMEParser.extractContentId(from: headerDict["content-id"])
        )]
    }
    
    // MARK: - Step: Body Selection
    
    private func selectBestBody(from parts: [MIMEPart]) -> BodySelectionResult {
        let candidates = BodySelectionHeuristic.parseMultipartAlternative(parts: parts)
        let heuristic = BodySelectionHeuristic(strategy: .smart)
        return heuristic.selectBestBody(from: candidates, relatedParts: parts)
    }
    
    // MARK: - Step: Process Attachments
    
    private func processAttachments(
        mimeParts: [MIMEPart],
        messageId: UUID
    ) async throws -> (attachments: [(id: UUID, blobId: String, filename: String)], errors: [String], warnings: [String]) {
        
        var attachments: [(UUID, String, String)] = []
        var errors: [String] = []
        var warnings: [String] = []
        
        for part in mimeParts {
            // Skip body parts
            if part.disposition != "attachment" && !part.mediaType.hasPrefix("image/") && !part.mediaType.hasPrefix("application/") {
                continue
            }
            
            do {
                // Decode content
                let decoded = try MIMEParser.decodeContent(
                    content: part.body,
                    encoding: part.transferEncoding
                )
                
                // Size check
                let sizeCheck = await limitsService.checkAttachmentSize(size: decoded.count)
                if case .exceeded(let msg, _, _) = sizeCheck {
                    errors.append(msg)
                    continue
                }
                if case .warning(let msg, _) = sizeCheck {
                    warnings.append(msg)
                }
                
                // Store blob
                let hash = SHA256.hash(data: decoded).compactMap { String(format: "%02x", $0) }.joined()
                try blobStore.store(data: decoded, hash: hash)
                
                // Create attachment record
                let attachmentId = UUID()
                let filename = part.filename ?? "attachment_\(part.partId)"
                
                try storeAttachment(
                    id: attachmentId,
                    messageId: messageId,
                    filename: filename,
                    mediaType: part.mediaType,
                    blobId: hash,
                    contentId: part.contentId,
                    disposition: part.disposition ?? "attachment",
                    size: decoded.count
                )
                
                // Security scan
                let scanResult = try await securityService.scanAttachment(
                    attachmentId: attachmentId,
                    blobId: hash,
                    originalContentType: part.mediaType,
                    filename: filename
                )
                
                if scanResult.status == .infected {
                    warnings.append("Attachment '\(filename)' is infected: \(scanResult.threatName ?? "Unknown")")
                }
                
                attachments.append((attachmentId, hash, filename))
                
            } catch {
                errors.append("Failed to process attachment \(part.filename ?? part.partId): \(error.localizedDescription)")
            }
        }
        
        return (attachments, errors, warnings)
    }
    
    // MARK: - Step: Finalize HTML
    
    private func finalizeHTML(
        html: String,
        messageId: UUID,
        inlineAttachments: [String]
    ) -> String {
        var finalHTML = html
        
        // Rewrite cid: URLs
        for cid in inlineAttachments {
            let cidPattern = "cid:\(cid)"
            if let url = servingService.generateCIDServingURL(messageId: messageId, contentId: cid) {
                finalHTML = finalHTML.replacingOccurrences(of: cidPattern, with: url.absoluteString)
            }
        }
        
        // Basic XSS sanitization
        finalHTML = sanitizeHTML(finalHTML)
        
        return finalHTML
    }
    
    private func sanitizeHTML(_ html: String) -> String {
        var sanitized = html
        
        // Remove script tags
        sanitized = sanitized.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>",
            with: "",
            options: .regularExpression
        )
        
        // Remove event handlers
        let eventHandlers = ["onclick", "onload", "onerror", "onmouseover"]
        for handler in eventHandlers {
            sanitized = sanitized.replacingOccurrences(
                of: "\(handler)=\"[^\"]*\"",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        return sanitized
    }
    
    // MARK: - Database Operations
    
    private func storeAttachment(
        id: UUID,
        messageId: UUID,
        filename: String,
        mediaType: String,
        blobId: String,
        contentId: String?,
        disposition: String,
        size: Int
    ) throws {
        let sql = """
        INSERT INTO attachments (
            id, message_id, filename, media_type, storage_key,
            content_id, disposition, size_bytes, inline_referenced,
            virus_scan_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Orchestrator", code: 8002, userInfo: nil)
        }
        
        sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (messageId.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (filename as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (mediaType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (blobId as NSString).utf8String, -1, nil)
        
        if let cid = contentId {
            sqlite3_bind_text(statement, 6, (cid as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        
        sqlite3_bind_text(statement, 7, (disposition as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 8, Int32(size))
        sqlite3_bind_int(statement, 9, disposition == "inline" ? 1 : 0)
        
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw NSError(domain: "Orchestrator", code: 8003, userInfo: nil)
        }
        
        sqlite3_finalize(statement)
    }
    
    private func storeRenderCache(messageId: UUID, html: String?, text: String?) throws {
        let sql = """
        INSERT OR REPLACE INTO render_cache (
            message_id, html_rendered, text_rendered, generated_at, generator_version
        ) VALUES (?, ?, ?, ?, 'v8')
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Orchestrator", code: 8004, userInfo: nil)
        }
        
        sqlite3_bind_text(statement, 1, (messageId.uuidString as NSString).utf8String, -1, nil)
        
        if let html = html {
            sqlite3_bind_text(statement, 2, (html as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        
        if let text = text {
            sqlite3_bind_text(statement, 3, (text as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        
        sqlite3_bind_int64(statement, 4, Int64(Date().timeIntervalSince1970))
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
    
    private func storeMessageMetadata(
        messageId: UUID,
        accountId: UUID,
        folder: String,
        uid: String,
        rawBlobId: String,
        headers: [EmailHeader],
        hasAttachments: Bool
    ) throws {
        let subject = headers.first { $0.name.lowercased() == "subject" }?.value ?? ""
        let from = headers.first { $0.name.lowercased() == "from" }?.value ?? ""
        
        let sql = """
        INSERT OR REPLACE INTO messages (
            id, account_id, mailbox, uid, raw_rfc822_blob_id,
            subject, from_addr, has_attachments
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Orchestrator", code: 8005, userInfo: nil)
        }
        
        sqlite3_bind_text(statement, 1, (messageId.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (accountId.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (folder as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (uid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (rawBlobId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (subject as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (from as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 8, hasAttachments ? 1 : 0)
        
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }
}

// MARK: - Usage Documentation

/*
 MESSAGE PROCESSING ORCHESTRATOR (Phase 8)
 ==========================================
 
 COMPLETE PIPELINE:
 ```swift
 let orchestrator = MessageProcessingOrchestrator(
     blobStore: blobStore,
     database: db,
     securityService: securityService,
     servingService: servingService,
     limitsService: limitsService
 )
 
 let result = try await orchestrator.processMessage(
     accountId: accountId,
     folder: "INBOX",
     uid: "123",
     rawRFC822: rawMessage
 )
 
 print("Status: \(result.status)")
 print("Attachments: \(result.attachmentCount)")
 print("Time: \(result.processingTime)s")
 ```
 
 PIPELINE STEPS:
 1. Check render cache (instant if cached)
 2. Size validation
 3. Store RAW to blob store
 4. Parse MIME structure
 5. Detect S/MIME/PGP parts
 6. Select best body (HTML/text)
 7. Process attachments + security scan
 8. Finalize HTML (CID rewrite + sanitize)
 9. Store render cache
 10. Store message metadata
 
 FEATURES:
 - Single entry point for all processing
 - Automatic cache check
 - Complete error handling
 - Warnings collection
 - Performance tracking
 - Partial success support
 */
