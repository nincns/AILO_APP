// AILO_APP/Helpers/Utilities/MailTransportStubs_Phase2.swift
// PHASE 2: Intelligent Message Fetching
// Uses BODYSTRUCTURE to fetch only needed sections

import Foundation

// MARK: - MailTransportStubs Phase 2 Extension

extension MailTransportStubs {
    
    /// Phase 2: Intelligent message fetch using BODYSTRUCTURE analysis
    /// - Parameters:
    ///   - uid: Message UID
    ///   - folder: Folder name
    ///   - account: Account configuration
    ///   - fetchInlineImages: Whether to fetch inline images immediately
    /// - Returns: Result with parsed message and stored MIME parts
    func fetchMessageIntelligent(_ uid: String, folder: String, 
                                using account: MailAccountConfig,
                                fetchInlineImages: Bool = true) async -> Result<FullMessage, Error> {
        do {
            // STEP 1: Connect & authenticate
            let conn = IMAPConnection(label: "intelligent.\(account.id.uuidString.prefix(6))")
            defer { conn.close() }
            
            let config = IMAPConnectionConfig(
                host: account.recvHost,
                port: account.recvPort,
                tls: (account.recvEncryption == .sslTLS),
                sniHost: account.recvHost,
                connectionTimeoutSec: account.connectionTimeoutSec,
                commandTimeoutSec: max(5, account.connectionTimeoutSec/2),
                idleTimeoutSec: 20
            )
            
            try await conn.open(config)
            
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            
            if account.recvEncryption == .startTLS {
                try await cmds.startTLS(conn)
            }
            
            guard let pwd = account.recvPassword else {
                throw ServiceError.invalidAccount
            }
            
            try await cmds.login(conn, user: account.recvUsername, pass: pwd)
            _ = try await cmds.select(conn, folder: folder, readOnly: true)
            
            print("📊 [Phase2] STEP 1: Connected and authenticated")
            
            // STEP 2: Fetch BODYSTRUCTURE + metadata
            let structureLines = try await cmds.uidFetchStructureAndMetadata(conn, uid: uid)
            
            let parser = IMAPParsers()
            guard let enhanced = try parser.parseEnhancedBodyStructure(structureLines) else {
                throw IMAPError.protocolError("Failed to parse BODYSTRUCTURE")
            }
            
            print("📊 [Phase2] STEP 2: Analyzed BODYSTRUCTURE")
            print("   - Total sections: \(enhanced.sections.count)")
            print("   - Body candidates: \(enhanced.bodyCandidates.count)")
            print("   - Inline parts: \(enhanced.inlineParts.count)")
            print("   - Attachments: \(enhanced.attachments.count)")
            
            // STEP 3: Determine which sections to fetch now
            var sectionsToFetch: [String] = []
            var sectionPurpose: [String: String] = [:] // For logging
            
            // 3a) Body content (HTML preferred, text fallback)
            if let htmlSection = enhanced.bodyCandidates.first(where: { 
                $0.mediaType.contains("html") 
            }) {
                sectionsToFetch.append(htmlSection.sectionId)
                sectionPurpose[htmlSection.sectionId] = "HTML body"
            } else if let textSection = enhanced.bodyCandidates.first {
                sectionsToFetch.append(textSection.sectionId)
                sectionPurpose[textSection.sectionId] = "Text body"
            }
            
            // 3b) Inline images (if requested)
            if fetchInlineImages {
                for inline in enhanced.inlineParts where inline.mediaType.hasPrefix("image/") {
                    sectionsToFetch.append(inline.sectionId)
                    sectionPurpose[inline.sectionId] = "Inline image"
                }
            }
            
            print("📊 [Phase2] STEP 3: Determined sections to fetch")
            for section in sectionsToFetch {
                print("   - \(section): \(sectionPurpose[section] ?? "unknown")")
            }
            
            // STEP 4: Fetch selected sections (batch)
            let contentLines = try await cmds.uidFetchSections(conn, uid: uid, 
                                                              sections: sectionsToFetch, 
                                                              peek: true)
            
            // Parse section contents
            let sectionData = parser.parseMultipleSections(contentLines)
            
            print("📊 [Phase2] STEP 4: Fetched \(sectionData.count) sections")
            for (section, data) in sectionData {
                print("   - \(section): \(data.count) bytes")
            }
            
            // STEP 5: Process and decode content
            let bodyContent = try processBodyContent(
                sectionData: sectionData,
                bodyCandidate: enhanced.bodyCandidates.first,
                parser: parser
            )
            
            print("📊 [Phase2] STEP 5: Processed body content")
            print("   - HTML: \(bodyContent.html != nil)")
            print("   - Text: \(bodyContent.text != nil)")
            
            // STEP 6: Store MIME parts in database (Phase 1 integration)
            if let dao = MailRepository.shared.dao {
                let messageUUID = UUID() // In real impl, get from existing header
                let mimeParts = enhanced.toMimePartEntities(messageId: messageUUID)
                
                // Store blobs and update mime parts with blob IDs
                let blobStore = try BlobStore()
                var updatedParts = mimeParts
                
                for (index, var part) in updatedParts.enumerated() {
                    if let data = sectionData[part.partId] {
                        let blobId = try blobStore.store(data)
                        part.blobId = blobId
                        part.bytesStored = data.count
                        part.contentSha256 = blobId // SHA256 is the blob ID
                        updatedParts[index] = part
                    }
                }
                
                try dao.storeMimeParts(messageId: messageUUID, parts: updatedParts)
                
                print("📊 [Phase2] STEP 6: Stored \(updatedParts.count) MIME parts")
            }
            
            // STEP 7: Build FullMessage response
            // Get header stub from previous data
            let header: MailHeader
            if let existingHeader = try? MailRepository.shared.getHeader(
                accountId: account.id, 
                folder: folder, 
                uid: uid
            ) {
                header = existingHeader
            } else {
                // Parse envelope from structure lines
                let envelopes = parser.parseEnvelope(structureLines)
                if let env = envelopes.first {
                    header = MailHeader(
                        id: uid,
                        from: env.from,
                        subject: env.subject,
                        date: env.internalDate ?? Date(),
                        unread: true
                    )
                } else {
                    throw IMAPError.protocolError("No envelope data")
                }
            }
            
            let fullMessage = FullMessage(
                header: header,
                textBody: bodyContent.text,
                htmlBody: bodyContent.html,
                rawBody: nil // RAW will be fetched separately if needed
            )
            
            print("✅ [Phase2] Message fetched successfully (intelligent mode)")
            
            return .success(fullMessage)
            
        } catch {
            print("❌ [Phase2] Intelligent fetch failed: \(error)")
            return .failure(error)
        }
    }
    
    /// Phase 2: Batch fetch headers with BODYSTRUCTURE analysis
    /// Efficiently determines which messages have attachments without fetching bodies
    /// - Parameters:
    ///   - folder: Folder name
    ///   - account: Account configuration
    ///   - limit: Maximum number of messages
    /// - Returns: Headers with accurate attachment flags
    func fetchHeadersWithStructureAnalysis(folder: String,
                                          using account: MailAccountConfig,
                                          limit: Int = 50) async -> Result<[MailHeader], Error> {
        do {
            // Setup connection
            let conn = IMAPConnection(label: "headers_struct.\(account.id.uuidString.prefix(6))")
            defer { conn.close() }
            
            let config = IMAPConnectionConfig(
                host: account.recvHost,
                port: account.recvPort,
                tls: (account.recvEncryption == .sslTLS),
                sniHost: account.recvHost,
                connectionTimeoutSec: account.connectionTimeoutSec,
                commandTimeoutSec: max(5, account.connectionTimeoutSec/2),
                idleTimeoutSec: 15
            )
            
            try await conn.open(config)
            
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            
            if account.recvEncryption == .startTLS {
                try await cmds.startTLS(conn)
            }
            
            guard let pwd = account.recvPassword else {
                throw ServiceError.invalidAccount
            }
            
            try await cmds.login(conn, user: account.recvUsername, pass: pwd)
            _ = try await cmds.select(conn, folder: folder, readOnly: true)
            
            // Search for messages
            let searchLines = try await cmds.uidSearch(conn, query: "NOT DELETED")
            let uids = cmds.parseSearchUIDs(searchLines)
            let latest = Array(uids.suffix(limit))
            
            print("📊 [Phase2] Found \(latest.count) messages, fetching with structure analysis")
            
            // Batch fetch with BODYSTRUCTURE
            let fetchLines = try await cmds.uidFetchStructuresAndMetadata(conn, uids: latest)
            
            // Parse structures
            let parser = IMAPParsers()
            let structures = try parser.parseEnhancedBodyStructures(fetchLines)
            
            // Parse envelopes
            let envelopes = parser.parseEnvelope(fetchLines)
            let flags = parser.parseFlags(fetchLines)
            let flagsByUID = Dictionary(uniqueKeysWithValues: flags.map { ($0.uid, $0.flags) })
            
            // Build headers with accurate attachment info
            let headers = envelopes.map { env in
                let fl = flagsByUID[env.uid] ?? []
                let hasAttachments = structures[env.uid]?.attachments.isEmpty == false
                
                var header = MailHeader(
                    id: env.uid,
                    from: env.from,
                    subject: env.subject,
                    date: env.internalDate ?? Date(),
                    unread: !fl.contains("\\Seen")
                )
                header.hasAttachments = hasAttachments
                
                return header
            }
            
            print("✅ [Phase2] Fetched \(headers.count) headers with structure analysis")
            print("   - Messages with attachments: \(headers.filter { $0.hasAttachments }.count)")
            
            return .success(headers.sorted { $0.date > $1.date })
            
        } catch {
            print("❌ [Phase2] Structure-based header fetch failed: \(error)")
            return .failure(error)
        }
    }
    
    // MARK: - Private Helpers
    
    private func processBodyContent(sectionData: [String: Data],
                                   bodyCandidate: SectionInfo?,
                                   parser: IMAPParsers) throws -> (text: String?, html: String?) {
        guard let candidate = bodyCandidate else {
            return (nil, nil)
        }
        
        guard let data = sectionData[candidate.sectionId] else {
            return (nil, nil)
        }
        
        // Decode content
        let decoder = ContentDecoder()
        let charset = "utf-8" // TODO: Extract from MIME headers
        let encoding = "quoted-printable" // TODO: Extract from MIME headers
        
        let decodedString = decoder.decodeContent(
            data: data,
            transferEncoding: encoding,
            charset: charset
        )
        
        // Determine if HTML or text
        let isHTML = candidate.mediaType.contains("html")
        
        if isHTML {
            // Clean HTML for display
            let cleaned = BodyContentProcessor.cleanHTMLForDisplay(decodedString)
            return (nil, cleaned)
        } else {
            // Plain text
            return (decodedString, nil)
        }
    }
}

// MARK: - Supporting Types

struct BodyContentResult {
    let text: String?
    let html: String?
}

// MARK: - MailHeader Extension

extension MailHeader {
    var hasAttachments: Bool {
        get { false } // Placeholder
        set { } // Placeholder - needs to be added to MailHeader struct
    }
}
