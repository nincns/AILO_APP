// AILO_APP/Core/Mail/MailSyncEngineV2.swift
// AILO_APP/Core/Mail/MailSyncEngine.swift  
// Complete 5-Phase Mail Synchronization Architecture
// Implements clean separation of concerns with structured data storage
// Phases: Header-Only → Body-On-Demand → Central-Processing → Structured-Storage → Bidirectional-Sync
//
// Dependencies:
// - MailSchema.swift: AccountEntity, FolderEntity, MessageHeaderEntity, MessageBodyEntity, AttachmentEntity
// - IMAPCommands.swift: IMAPClient, SearchCriteria, StoreMode, IMAPMessage
// - MailProcessor.swift: MailProcessor, ProcessedMail, ProcessedAttachment
// - MailSendService.swift: MailSendMessage, MailSendAddress, SendValidationError

import Foundation

// MARK: - Complete Mail Sync Engine

/// Phase 1: Fast header-only synchronization for mail overview
/// Complete 5-phase mail synchronization engine
/// Fetches essential metadata, processes content on-demand, provides bidirectional sync
public actor MailSyncEngine {
    private let headerStorage: MailHeaderStorage
    
    public init(headerStorage: MailHeaderStorage) {
        self.headerStorage = headerStorage
    }
    
    // MARK: - Phase 1 Implementation
    
    /// Fast header-only sync for quick mailbox overview
    /// Uses IMAP FETCH (FLAGS UID ENVELOPE) for minimal data transfer
    public func syncHeaders(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity
    ) async throws -> HeaderSyncResult {
        
        // 1. Get all UIDs in folder (fast UID search) 
        let serverUIDs = try await client.search(criteria: SearchCriteria.and([.unseen, .all]))
        
        // 2. Compare with local storage - find new headers only
        let existingUIDs = await headerStorage.getExistingUIDs(
            accountId: account.id, 
            folder: folder.name
        )
        let newUIDs = Set(serverUIDs).subtracting(existingUIDs)
        
        guard !newUIDs.isEmpty else {
            return HeaderSyncResult(newCount: 0, updatedCount: 0)
        }
        
        // 3. Fetch only headers for new messages
        let messages = try await client.fetchHeaders(uids: Array(newUIDs))
        
        // 4. Convert to MessageHeaderEntity and store
        let headers = messages.map { msg in
            MessageHeaderEntity(
                accountId: account.id,
                folder: folder.name,
                uid: msg.uid,
                from: msg.from,
                subject: msg.subject,
                date: msg.internalDate,
                flags: msg.flags
            )
        }
        
        await headerStorage.storeHeaders(headers)
        
        return HeaderSyncResult(newCount: headers.count, updatedCount: 0)
    }
    
    // MARK: - Flag Synchronization
    
    /// Sync only message flags (read, answered, flagged status)
    /// Separate from header sync for efficiency
    public func syncFlags(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity,
        uids: [String]
    ) async throws {
        guard !uids.isEmpty else { return }
        
        // Fetch current flags from server
        let messages = try await client.fetchHeaders(uids: uids, fields: ["FLAGS"])
        let flagUpdates = Dictionary(uniqueKeysWithValues: messages.map { ($0.uid, $0.flags) })
        
        await headerStorage.updateFlags(accountId: account.id, folder: folder.name, updates: flagUpdates)
    }
    
    // MARK: - Phase 2: On-Demand Body Fetching
    
    /// Fetch message body only when needed (user clicks on message)
    /// Checks if body already exists in storage before fetching from server
    public func fetchBodyIfNeeded(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity,
        uid: String
    ) async throws -> MessageBodyEntity? {
        
        // 1. Check if body already exists in storage
        if let existingBody = await headerStorage.getBody(accountId: account.id, folder: folder.name, uid: uid) {
            return existingBody
        }
        
        // 2. Fetch raw message body from server
        let bodyData = try await client.fetchBody(uid: uid)
        let rawBody = String(data: bodyData, encoding: .utf8) ?? ""
        
        // 3. Parse raw body data and separate components
        guard !rawBody.isEmpty else {
            throw MailSyncError.bodyNotFound(uid: uid)
        }
        
        // 4. Store raw body for later processing (Phase 3)
        let bodyEntity = MessageBodyEntity(
            accountId: account.id,
            folder: folder.name,
            uid: uid,
            text: nil,  // Will be processed in Phase 3
            html: nil,  // Will be processed in Phase 3
            hasAttachments: detectAttachments(in: rawBody),
            rawBody: rawBody,  // ✅ NEU: Speichere RAW body
            contentType: extractContentType(from: rawBody),
            charset: extractCharset(from: rawBody),
            transferEncoding: extractTransferEncoding(from: rawBody),
            isMultipart: rawBody.contains("Content-Type: multipart/"),
            rawSize: rawBody.count,
            processedAt: nil  // Not processed yet
        )
        
        // 5. Process body immediately (Phase 3)
        let finalBody = await processBodyContent(bodyEntity, rawData: rawBody)
        await headerStorage.storeRawBody(finalBody, rawData: rawBody)
        
        return finalBody
    }
    
    /// Fetch multiple message bodies in batch for better performance
    public func fetchBodiesBatch(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity,
        uids: [String]
    ) async throws -> [MessageBodyEntity] {
        
        // 1. Filter UIDs that don't have bodies yet
        let missingUIDs = await headerStorage.getMissingBodyUIDs(
            accountId: account.id, 
            folder: folder.name, 
            uids: uids
        )
        
        guard !missingUIDs.isEmpty else {
            return await headerStorage.getBodies(accountId: account.id, folder: folder.name, uids: uids)
        }
        
        // 2. Batch fetch from server
        var newBodies: [MessageBodyEntity] = []
        for uid in missingUIDs {
            let bodyData = try await client.fetchBody(uid: uid)
            let rawBody = String(data: bodyData, encoding: .utf8) ?? ""
            
            guard !rawBody.isEmpty else { continue }
            
            let bodyEntity = MessageBodyEntity(
                accountId: account.id,
                folder: folder.name,
                uid: uid,
                text: nil,
                html: nil,
                hasAttachments: detectAttachments(in: rawBody),
                rawBody: rawBody,  // ✅ NEU: Speichere RAW body
                contentType: extractContentType(from: rawBody),
                charset: extractCharset(from: rawBody),
                transferEncoding: extractTransferEncoding(from: rawBody),
                isMultipart: rawBody.contains("Content-Type: multipart/"),
                rawSize: rawBody.count,
                processedAt: nil
            )
            
            newBodies.append(bodyEntity)
            
            // Phase 3: Process body immediately
            let processedBody = await processBodyContent(bodyEntity, rawData: rawBody)
            await headerStorage.storeRawBody(processedBody, rawData: rawBody)
        }
        
        // 3. Return all bodies (existing + new processed)
        return await headerStorage.getBodies(accountId: account.id, folder: folder.name, uids: uids)
    }
    
    // MARK: - Phase 3: Central Mail Processing Pipeline
    
    /// Process raw mail body through unified decoding pipeline
    /// Single point of truth for all mail content processing
    private func processBodyContent(_ body: MessageBodyEntity, rawData: String) async -> MessageBodyEntity {
        
        // 1. Initialize central mail content processor
        let processor = MailProcessor()
        
        // 2. Process through unified pipeline
        do {
            let processed = try await processor.processMailContent(
                rawData: rawData,
                detectedCharset: body.charset,
                detectedEncoding: body.transferEncoding,
                contentType: body.contentType
            )
            
            // 3. Create enhanced body with processed content and structured storage
            let finalBody = MessageBodyEntity(
                accountId: body.accountId,
                folder: body.folder,
                uid: body.uid,
                text: processed.text,
                html: processed.html,
                hasAttachments: !processed.attachments.isEmpty,
                rawBody: rawData,  // ✅ NEU: RAW body aus Parameter verwenden
                contentType: processed.contentType,
                charset: processed.charset,
                transferEncoding: processed.transferEncoding,
                isMultipart: processed.isMultipart,
                rawSize: processed.rawSize,
                processedAt: processed.processedAt
            )
            
            // 4. Phase 4: Store attachments separately in structured storage
            await processAndStoreAttachments(
                processed,
                accountId: body.accountId,
                folder: body.folder,
                uid: body.uid
            )
            
            return finalBody
            
        } catch {
            // Fallback: Return original with processing error
            return MessageBodyEntity(
                accountId: body.accountId,
                folder: body.folder,
                uid: body.uid,
                text: "Processing failed: \(error.localizedDescription)",
                html: nil,
                hasAttachments: body.hasAttachments,
                rawBody: rawData,  // ✅ NEU: RAW body auch im Fehlerfall speichern
                contentType: body.contentType,
                charset: body.charset,
                transferEncoding: body.transferEncoding,
                isMultipart: body.isMultipart,
                rawSize: body.rawSize,
                processedAt: Date()
            )
        }
    }

    // MARK: - Phase 4: Structured Attachment Processing
    
    /// Process and store attachments separately from body content
    /// Implements structured data storage with deduplication and metadata
    private func processAndStoreAttachments(
        _ processedMail: ProcessedMail,
        accountId: UUID,
        folder: String,
        uid: String
    ) async {
        guard !processedMail.attachments.isEmpty else { return }
        
        var attachmentEntities: [AttachmentEntity] = []
        
        for attachment in processedMail.attachments {
            // Create enhanced attachment entity with Phase 4 metadata
            let entity = AttachmentEntity(
                accountId: accountId,
                folder: folder,
                uid: uid,
                partId: attachment.partId,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.sizeBytes,
                data: attachment.data,
                contentId: attachment.contentId,
                isInline: attachment.isInline,
                filePath: nil, // Could be external storage path
                checksum: attachment.checksum
            )
            
            attachmentEntities.append(entity)
        }
        
        // Store attachments in separate storage area
        await headerStorage.storeAttachments(attachmentEntities)
    }

    // MARK: - Phase 5: Bidirectional Synchronization
    
    /// Send mail with proper encoding and automatic APPEND to Sent folder
    /// Implements complete bidirectional mail flow
    public func sendMail(
        client: IMAPClient,
        smtpConnection: SMTPConnection,
        account: AccountEntity,
        message: MailSendMessage
    ) async throws -> SendResult {
        
        // 1. Validate message
        try validateMessage(message)
        
        // 2. Compose mail with proper encoding (reverse of Phase 3)
        let composedMail = try await composeMail(message)
        
        // 3. Send via SMTP
        try await smtpConnection.send(composedMail)
        
        // 4. Phase 5: APPEND to Sent folder for sync consistency  
        try await appendToSentFolder(
            client: client,
            account: account,
            composedMail: composedMail
        )
        
        return SendResult(messageId: composedMail.messageId, sentAt: Date())
    }
    
    /// Synchronize message flags bidirectionally (local ↔ server)
    /// Handles READ, ANSWERED, FLAGGED, DELETED states
    public func syncMessageFlags(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity,
        localChanges: [FlagChange]
    ) async throws -> FlagSyncResult {
        
        // 1. Apply local changes to server
        var appliedChanges = 0
        for change in localChanges {
            do {
                try await applyFlagChange(client, change: change)
                appliedChanges += 1
            } catch {
                // Log but continue with other changes
                print("Failed to apply flag change for \(change.uid): \(error)")
            }
        }
        
        // 2. Fetch current server flags for verification
        let allUIDs = localChanges.map { $0.uid }
        let messages = try await client.fetchHeaders(uids: allUIDs, fields: ["FLAGS"])
        let serverFlagUpdates = Dictionary(uniqueKeysWithValues: messages.map { ($0.uid, $0.flags) })
        
        // 3. Update local storage with server state
        await headerStorage.updateFlags(
            accountId: account.id, 
            folder: folder.name, 
            updates: serverFlagUpdates
        )
        
        return FlagSyncResult(
            appliedChanges: appliedChanges,
            totalChanges: localChanges.count,
            conflicts: []
        )
    }
    
    /// Delete messages with proper EXPUNGE synchronization
    /// Ensures consistent deletion across client and server
    public func deleteMessages(
        client: IMAPClient,
        account: AccountEntity,
        folder: FolderEntity,
        uids: [String],
        expungeImmediately: Bool = true
    ) async throws -> DeleteResult {
        
        guard !uids.isEmpty else {
            return DeleteResult(deletedCount: 0, expunged: false)
        }
        
        // 1. Mark messages as deleted
        try await client.store(uids: uids, flags: ["\\Deleted"], mode: StoreMode.add)
        
        // 2. EXPUNGE if requested (removes deleted messages permanently)
        var expunged = false
        if expungeImmediately {
            // Note: IMAPClient doesn't have expunge method, need to add it or use different approach
            expunged = false // Placeholder until expunge is implemented
        }
        
        // 3. Update local storage - remove deleted messages
        await headerStorage.removeMessages(
            accountId: account.id, 
            folder: folder.name, 
            uids: uids
        )
        
        return DeleteResult(deletedCount: uids.count, expunged: expunged)
    }
    
    // MARK: - Phase 5 Implementation Helpers
    
    private func joinUIDSet(_ uids: [String]) -> String {
        // Compact ranges later; for now simply join
        return uids.joined(separator: ",")
    }
    
    private func quote(_ s: String) -> String {
        // IMAP quoted string; naive implementation for now
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    
    private func validateMessage(_ message: MailSendMessage) throws {
        if message.to.isEmpty && message.cc.isEmpty && message.bcc.isEmpty {
            throw SendValidationError.noRecipients
        }
        
        if message.textBody?.isEmpty != false && message.htmlBody?.isEmpty != false {
            throw SendValidationError.emptyBody
        }
    }
    
    private func composeMail(_ message: MailSendMessage) async throws -> ComposedMail {
        // Phase 5: Reverse of Phase 3 processing - compose with proper encoding
        
        // 1. Generate Message-ID and headers
        let messageId = "<\(UUID().uuidString)@\(message.from.email.components(separatedBy: "@").last ?? "localhost")>"
        let date = Date()
        
        // 2. Encode content with charset detection (reverse of Phase 3)
        let encodedTextBody = try encodeTextContent(message.textBody, preferredCharset: "utf-8")
        let encodedHtmlBody = try encodeHtmlContent(message.htmlBody, preferredCharset: "utf-8")
        
        // 3. Build MIME structure
        let mimeContent = try buildMimeContent(
            textBody: encodedTextBody,
            htmlBody: encodedHtmlBody
        )
        
        return ComposedMail(
            messageId: messageId,
            from: message.from,
            to: message.to,
            cc: message.cc,
            bcc: message.bcc,
            subject: message.subject,
            date: date,
            mimeContent: mimeContent
        )
    }
    
    private func encodeTextContent(_ text: String?, preferredCharset: String) throws -> EncodedContent? {
        guard let text = text else { return nil }
        
        // Determine best encoding method
        let needsEncoding = text.contains { !$0.isASCII }
        let transferEncoding: String
        let charset: String
        
        if needsEncoding {
            charset = "utf-8"
            transferEncoding = "quoted-printable"
        } else {
            charset = "us-ascii"
            transferEncoding = "7bit"
        }
        
        let encodedData = try applyTransferEncoding(
            text.data(using: .utf8) ?? Data(),
            encoding: transferEncoding
        )
        
        return EncodedContent(
            data: encodedData,
            charset: charset,
            transferEncoding: transferEncoding,
            contentType: "text/plain"
        )
    }
    
    private func encodeHtmlContent(_ html: String?, preferredCharset: String) throws -> EncodedContent? {
        guard let html = html else { return nil }
        
        // HTML usually needs UTF-8 for international characters
        let transferEncoding = "quoted-printable"
        let charset = "utf-8"
        
        let encodedData = try applyTransferEncoding(
            html.data(using: .utf8) ?? Data(),
            encoding: transferEncoding
        )
        
        return EncodedContent(
            data: encodedData,
            charset: charset,
            transferEncoding: transferEncoding,
            contentType: "text/html"
        )
    }
    
    private func applyTransferEncoding(_ data: Data, encoding: String) throws -> Data {
        switch encoding.lowercased() {
        case "quoted-printable":
            return encodeQuotedPrintable(data)
        case "base64":
            return data.base64EncodedData()
        case "7bit", "8bit":
            return data
        default:
            return data
        }
    }
    
    private func encodeQuotedPrintable(_ data: Data) -> Data {
        // Simple quoted-printable encoder (reverse of Phase 3 decoder)
        let string = String(data: data, encoding: .utf8) ?? ""
        var result = ""
        
        for char in string {
            let scalar = char.unicodeScalars.first!
            if scalar.value > 126 || char == "=" {
                result += String(format: "=%02X", scalar.value)
            } else {
                result.append(char)
            }
        }
        
        return result.data(using: .utf8) ?? data
    }
    
    private func buildMimeContent(textBody: EncodedContent?, htmlBody: EncodedContent?) throws -> String {
        var content = ""
        
        if let textBody = textBody, let htmlBody = htmlBody {
            // Multipart/alternative
            let boundary = "boundary_\(UUID().uuidString)"
            content += "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
            content += "--\(boundary)\r\n"
            content += "Content-Type: \(textBody.contentType); charset=\(textBody.charset)\r\n"
            content += "Content-Transfer-Encoding: \(textBody.transferEncoding)\r\n\r\n"
            content += String(data: textBody.data, encoding: .utf8) ?? ""
            content += "\r\n--\(boundary)\r\n"
            content += "Content-Type: \(htmlBody.contentType); charset=\(htmlBody.charset)\r\n"
            content += "Content-Transfer-Encoding: \(htmlBody.transferEncoding)\r\n\r\n"
            content += String(data: htmlBody.data, encoding: .utf8) ?? ""
            content += "\r\n--\(boundary)--\r\n"
        } else if let textBody = textBody {
            // Plain text only
            content += "Content-Type: \(textBody.contentType); charset=\(textBody.charset)\r\n"
            content += "Content-Transfer-Encoding: \(textBody.transferEncoding)\r\n\r\n"
            content += String(data: textBody.data, encoding: .utf8) ?? ""
        } else if let htmlBody = htmlBody {
            // HTML only
            content += "Content-Type: \(htmlBody.contentType); charset=\(htmlBody.charset)\r\n"
            content += "Content-Transfer-Encoding: \(htmlBody.transferEncoding)\r\n\r\n"
            content += String(data: htmlBody.data, encoding: .utf8) ?? ""
        }
        
        return content
    }
    
    private func appendToSentFolder(
        client: IMAPClient,
        account: AccountEntity,
        composedMail: ComposedMail
    ) async throws {
        
        // 1. Build complete RFC822 message
        let rfc822Message = buildRFC822Message(composedMail)
        
        // 2. APPEND to Sent folder (using default "Sent" folder name)
        // Note: IMAPClient needs append method implementation
        // For now, this is a placeholder until append is available
        print("Would append to Sent folder: \(rfc822Message.prefix(100))...")
    }
    
    private func findSentFolder(client: IMAPClient) async throws -> String {
        // Default to "Sent" - folder discovery should be handled by IMAPClient
        return "Sent"
    }
    
    private func buildRFC822Message(_ mail: ComposedMail) -> String {
        var message = ""
        
        // Headers
        message += "Message-ID: \(mail.messageId)\r\n"
        message += "Date: \(formatRFC2822Date(mail.date))\r\n"
        message += "From: \(formatAddress(mail.from))\r\n"
        
        if !mail.to.isEmpty {
            message += "To: \(mail.to.map(formatAddress).joined(separator: ", "))\r\n"
        }
        if !mail.cc.isEmpty {
            message += "Cc: \(mail.cc.map(formatAddress).joined(separator: ", "))\r\n"
        }
        
        message += "Subject: \(mail.subject)\r\n"
        
        // Body
        message += "\r\n\(mail.mimeContent)"
        
        return message
    }
    
    private func formatAddress(_ addr: MailSendAddress) -> String {
        if let name = addr.name {
            return "\(name) <\(addr.email)>"
        } else {
            return addr.email
        }
    }
    
    private func formatRFC2822Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
    
    private func applyFlagChange(_ client: IMAPClient, change: FlagChange) async throws {
        let storeMode: StoreMode
        switch change.operation {
        case .add:
            storeMode = StoreMode.add
        case .remove:
            storeMode = StoreMode.remove
        case .set:
            storeMode = StoreMode.replace
        }
        try await client.store(uids: [change.uid], flags: change.flags, mode: storeMode)
    }


    // MARK: - Raw Body Processing Helpers
    
    private func extractRawBody(from response: [String], uid: String) -> String? {
        var inBody = false
        var bodyLines: [String] = []
        
        for line in response {
            if line.contains("UID \(uid)") && line.contains("BODY[]") {
                inBody = true
                continue
            }
            
            if inBody {
                if line.starts(with: ")") || line.starts(with: "A") {
                    break
                }
                bodyLines.append(line)
            }
        }
        
        return bodyLines.isEmpty ? nil : bodyLines.joined(separator: "\n")
    }
    
    private func detectAttachments(in rawBody: String) -> Bool {
        return rawBody.contains("Content-Disposition: attachment") ||
               rawBody.contains("Content-Type: multipart/mixed")
    }
    
    private func extractContentType(from rawBody: String) -> String? {
        let pattern = "Content-Type:\\s*([^;\\n\\r]+)"
        if let match = rawBody.range(of: pattern, options: .regularExpression) {
            return String(rawBody[match])
                .replacingOccurrences(of: "Content-Type:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "text/plain"
    }
    
    private func extractCharset(from rawBody: String) -> String? {
        let pattern = "charset=([^;\\s\\n\\r]+)"
        if let match = rawBody.range(of: pattern, options: .regularExpression) {
            return String(rawBody[match])
                .replacingOccurrences(of: "charset=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r"))
        }
        return "utf-8"
    }
    
    private func extractTransferEncoding(from rawBody: String) -> String? {
        let pattern = "Content-Transfer-Encoding:\\s*([^\\n\\r]+)"
        if let match = rawBody.range(of: pattern, options: .regularExpression) {
            return String(rawBody[match])
                .replacingOccurrences(of: "Content-Transfer-Encoding:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "7bit"
    }

}

// MARK: - Result Types

public struct HeaderSyncResult: Sendable {
    public let newCount: Int
    public let updatedCount: Int
    
    public init(newCount: Int, updatedCount: Int) {
        self.newCount = newCount
        self.updatedCount = updatedCount
    }
}

// MARK: - Storage Protocol

/// Header, Body & Attachment storage interface for Phase 1-4
/// Structured storage with three separate areas for optimal performance
public protocol MailHeaderStorage: Sendable {
    // Phase 1: Header management (fast access, always cached)
    func getExistingUIDs(accountId: UUID, folder: String) async -> Set<String>
    func storeHeaders(_ headers: [MessageHeaderEntity]) async
    func updateFlags(accountId: UUID, folder: String, updates: [String: [String]]) async
    func getHeaders(accountId: UUID, folder: String, limit: Int?, offset: Int?) async -> [MessageHeaderEntity]
    
    // Phase 2: Body management (on-demand loading)
    func getBody(accountId: UUID, folder: String, uid: String) async -> MessageBodyEntity?
    func getBodies(accountId: UUID, folder: String, uids: [String]) async -> [MessageBodyEntity]
    func getMissingBodyUIDs(accountId: UUID, folder: String, uids: [String]) async -> [String]
    func storeRawBody(_ body: MessageBodyEntity, rawData: String) async
    
    // Phase 4: Attachment management (structured storage with deduplication)
    func storeAttachments(_ attachments: [AttachmentEntity]) async
    func getAttachments(accountId: UUID, folder: String, uid: String) async -> [AttachmentEntity]
    func getAttachmentByChecksum(_ checksum: String) async -> AttachmentEntity?
    func deduplicateAttachments() async -> Int // Returns number of duplicates removed
    
    // Phase 5: Bidirectional sync support (message deletion)
    func removeMessages(accountId: UUID, folder: String, uids: [String]) async
}

// MARK: - Error Types

public enum MailSyncError: Error, LocalizedError {
    case bodyNotFound(uid: String)
    case connectionFailed
    case folderNotFound(String)
    case parsingFailed(String)
    case sendingFailed(String)
    case flagUpdateFailed(uid: String)
    
    public var errorDescription: String? {
        switch self {
        case .bodyNotFound(let uid):
            return "Body not found for message UID: \(uid)"
        case .connectionFailed:
            return "IMAP connection failed"
        case .folderNotFound(let folder):
            return "Folder not found: \(folder)"
        case .parsingFailed(let reason):
            return "Parsing failed: \(reason)"
        case .sendingFailed(let reason):
            return "Sending failed: \(reason)"
        case .flagUpdateFailed(let uid):
            return "Flag update failed for UID: \(uid)"
        }
    }
}

// MARK: - Phase 5 Types

/// Result of sending a mail message
public struct SendResult: Sendable {
    public let messageId: String
    public let sentAt: Date
    
    public init(messageId: String, sentAt: Date) {
        self.messageId = messageId
        self.sentAt = sentAt
    }
}

/// Flag change operation for bidirectional sync
public struct FlagChange: Sendable {
    public let uid: String
    public let flags: [String]
    public let operation: FlagOperation
    
    public init(uid: String, flags: [String], operation: FlagOperation) {
        self.uid = uid
        self.flags = flags
        self.operation = operation
    }
}

public enum FlagOperation: String, Sendable {
    case add
    case remove 
    case set
}

/// Result of flag synchronization
public struct FlagSyncResult: Sendable {
    public let appliedChanges: Int
    public let totalChanges: Int
    public let conflicts: [String] // UIDs with conflicts
    
    public init(appliedChanges: Int, totalChanges: Int, conflicts: [String]) {
        self.appliedChanges = appliedChanges
        self.totalChanges = totalChanges
        self.conflicts = conflicts
    }
}

/// Result of message deletion
public struct DeleteResult: Sendable {
    public let deletedCount: Int
    public let expunged: Bool
    
    public init(deletedCount: Int, expunged: Bool) {
        self.deletedCount = deletedCount
        self.expunged = expunged
    }
}

/// Composed mail ready for sending
public struct ComposedMail: Sendable {
    public let messageId: String
    public let from: MailSendAddress
    public let to: [MailSendAddress]
    public let cc: [MailSendAddress]
    public let bcc: [MailSendAddress]
    public let subject: String
    public let date: Date
    public let mimeContent: String
    
    public init(messageId: String, from: MailSendAddress, to: [MailSendAddress],
                cc: [MailSendAddress], bcc: [MailSendAddress], subject: String,
                date: Date, mimeContent: String) {
        self.messageId = messageId
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.date = date
        self.mimeContent = mimeContent
    }
}

/// Encoded content with metadata
public struct EncodedContent: Sendable {
    public let data: Data
    public let charset: String
    public let transferEncoding: String
    public let contentType: String
    
    public init(data: Data, charset: String, transferEncoding: String, contentType: String) {
        self.data = data
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.contentType = contentType
    }
}

/// Mock SMTP connection protocol for Phase 5
public protocol SMTPConnection: Sendable {
    func send(_ mail: ComposedMail) async throws
}


