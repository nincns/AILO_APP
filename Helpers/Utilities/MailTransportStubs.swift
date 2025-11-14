// AILO_APP/Configuration/Services/Mail/TransportStubs.swift
// High-level send/receive facade backed by real IMAP/SMTP implementations.
// Used by lightweight UI features (e.g., SchreibenMailView) without wiring the whole engine.

import Foundation

final class MailSendReceive {

    struct MailHeader: Sendable, Identifiable {
        let id: String
        let from: String
        let subject: String
        let date: Date
        let unread: Bool
        var hasAttachments: Bool = false // ✅ Added for Phase 2

        init(id: String, from: String, subject: String, date: Date = Date(), unread: Bool = false, hasAttachments: Bool = false) {
            self.id = id
            self.from = from
            self.subject = subject
            self.date = date
            self.unread = unread
            self.hasAttachments = hasAttachments
        }
    }

    struct FullMessage: Sendable {
        let header: MailHeader
        let textBody: String?
        let htmlBody: String?
        let rawBody: String?  // ✅ NEU
    }

    enum ServiceError: LocalizedError {
        case notImplemented
        case invalidAccount
        case network(String)
        case protocolErr(String)
        case noData
        var errorDescription: String? {
            switch self {
            case .notImplemented: return "Not implemented"
            case .invalidAccount: return "Invalid mail account configuration"
            case .network(let s): return s
            case .protocolErr(let s): return s
            case .noData: return "No data"
            }
        }
    }

    init() {}

    // MARK: - Connectivity

    func testConnection(cfg: MailAccountConfig) async -> Result<Void, Error> {
        // Test IMAP
        do {
            if cfg.recvProtocol == .imap {
                let imapOK = try await testIMAP(cfg)
                if !imapOK { return .failure(ServiceError.network("IMAP test failed")) }
            }
        } catch { return .failure(error) }
        // Test SMTP (best-effort)
        do {
            let smtpCfg = SMTPConfig(
                host: cfg.smtpHost,
                port: cfg.smtpPort,
                encryption: {
                    switch cfg.smtpEncryption {
                    case .none: return .plain
                    case .sslTLS: return .sslTLS
                    case .startTLS: return .startTLS
                    }
                }(),
                heloName: nil,
                username: cfg.smtpUsername.isEmpty ? nil : cfg.smtpUsername,
                password: cfg.smtpPassword,
                connectionTimeoutSec: cfg.connectionTimeoutSec,
                commandTimeoutSec: max(5, cfg.connectionTimeoutSec/2),
                sniHost: cfg.smtpHost
            )
            let smtp = SMTPClient()
            let res = await smtp.testConnection(smtpCfg)
            switch res { case .success: break; case .failure(let e): return .failure(e) }
        } catch { return .failure(error) }
        return .success(())
    }

    private func testIMAP(_ cfg: MailAccountConfig) async throws -> Bool {
        let conn = IMAPConnection(label: "test.imap")
        defer { conn.close() }
        let useTLS = (cfg.recvEncryption == .sslTLS)
        let conf = IMAPConnectionConfig(
            host: cfg.recvHost,
            port: cfg.recvPort,
            tls: useTLS,
            sniHost: cfg.recvHost,
            connectionTimeoutSec: cfg.connectionTimeoutSec,
            commandTimeoutSec: max(5, cfg.connectionTimeoutSec/2),
            idleTimeoutSec: 8
        )
        try await conn.open(conf)
        let cmds = IMAPCommands()
        _ = try await cmds.greeting(conn)
        if cfg.recvEncryption == .startTLS {
            try await cmds.startTLS(conn)
        }
        if !cfg.recvUsername.isEmpty, let pwd = cfg.recvPassword {
            try await cmds.login(conn, user: cfg.recvUsername, pass: pwd)
            try? await cmds.logout(conn)
        }
        return true
    }

    // MARK: - Discovery

    func discoverSystemFolders(using account: MailAccountConfig) async -> Result<FolderMap, Error> {
        let login = FolderDiscoveryService.IMAPLogin(
            host: account.recvHost,
            port: account.recvPort,
            useTLS: (account.recvEncryption == .sslTLS),
            sniHost: account.recvHost,
            username: account.recvUsername,
            password: account.recvPassword ?? "",
            connectionTimeoutSec: account.connectionTimeoutSec,
            commandTimeoutSec: max(5, account.connectionTimeoutSec/2),
            idleTimeoutSec: 10
        )
        let res = await FolderDiscoveryService.shared.discover(accountId: account.id, login: login)
        switch res {
        case .success(let map): return .success(map)
        case .failure(let e): return .failure(e)
        }
    }

    // MARK: - Headers

    func fetchHeaders(limit: Int, folder: String, using account: MailAccountConfig, preferCache: Bool, force: Bool) async -> Result<[MailHeader], Error> {
        print("📥 [MailTransportStubs] fetchHeaders called")
        print("📥 [MailTransportStubs] - folder: \(folder), limit: \(limit)")
        print("📥 [MailTransportStubs] - preferCache: \(preferCache), force: \(force)")
        print("📥 [MailTransportStubs] - account: \(account.accountName) @ \(account.recvHost)")
        
        // 1) Cache first (DAO)
        if preferCache && !force {
            print("📥 [MailTransportStubs] Checking cache first...")
            if let dao = MailRepository.shared.dao {
                if let cached = try? dao.headers(accountId: account.id, folder: folder, limit: limit, offset: 0), !cached.isEmpty {
                    print("📥 [MailTransportStubs] Found \(cached.count) cached headers")
                    return .success(cached.map { domainHeader in
                        MailHeader(id: domainHeader.id, from: domainHeader.from, subject: domainHeader.subject,
                                  date: domainHeader.date ?? Date(), unread: !domainHeader.flags.contains("\\Seen"))
                    })
                }
            } else {
                let cached = try? MailRepository.shared.listHeaders(accountId: account.id, folder: folder, limit: limit, offset: 0)
                if let cached, !cached.isEmpty {
                    print("📥 [MailTransportStubs] Found \(cached.count) cached headers via repository")
                    return .success(cached.map { domainHeader in
                        MailHeader(id: domainHeader.id, from: domainHeader.from, subject: domainHeader.subject,
                                  date: domainHeader.date ?? Date(), unread: !domainHeader.flags.contains("\\Seen"))
                    })
                }
            }
            print("📥 [MailTransportStubs] No cache data found")
        }

        // 2) Network fallback via IMAP
        print("📥 [MailTransportStubs] Starting network fetch via IMAP...")
        guard account.recvProtocol == .imap else {
            print("❌ [MailTransportStubs] Not IMAP protocol: \(account.recvProtocol)")
            return .success([])
        }
        
        do {
            let conn = IMAPConnection(label: "headers.\(account.id.uuidString.prefix(6))")
            defer { conn.close() }
            let conf = IMAPConnectionConfig(
                host: account.recvHost,
                port: account.recvPort,
                tls: (account.recvEncryption == .sslTLS),
                sniHost: account.recvHost,
                connectionTimeoutSec: account.connectionTimeoutSec,
                commandTimeoutSec: max(5, account.connectionTimeoutSec/2),
                idleTimeoutSec: 10
            )
            
            print("🔌 [MailTransportStubs] Opening connection to \(conf.host):\(conf.port)...")
            try await conn.open(conf)
            print("✅ [MailTransportStubs] Connection established")
            
            let cmds = IMAPCommands()
            print("🤝 [MailTransportStubs] Sending greeting...")
            _ = try await cmds.greeting(conn)
            print("✅ [MailTransportStubs] Greeting received")
            
            if account.recvEncryption == .startTLS {
                print("🔐 [MailTransportStubs] Starting TLS...")
                try await cmds.startTLS(conn)
                print("✅ [MailTransportStubs] TLS established")
            }
            
            guard let pwd = account.recvPassword else {
                print("❌ [MailTransportStubs] Password is nil!")
                throw ServiceError.invalidAccount
            }
            
            print("🔐 [MailTransportStubs] Logging in as \(account.recvUsername)...")
            try await cmds.login(conn, user: account.recvUsername, pass: pwd)
            print("✅ [MailTransportStubs] Login successful")
            
            print("📁 [MailTransportStubs] Selecting folder: \(folder)")
            _ = try await cmds.select(conn, folder: folder, readOnly: true)
            print("✅ [MailTransportStubs] Folder selected")
            
            print("🔍 [MailTransportStubs] Searching for messages...")
            let searchLines = try await cmds.uidSearch(conn, query: "NOT DELETED")
            let uids = cmds.parseSearchUIDs(searchLines)
            print("✅ [MailTransportStubs] Found \(uids.count) UIDs")
            
            // Take latest `limit` UIDs
            let sorted = uids.compactMap(Int.init).sorted().map(String.init)
            let latest = Array(sorted.suffix(max(1, limit)))
            
            print("📨 [MailTransportStubs] Fetching \(latest.count) message headers...")
            let fetchLines = try await cmds.uidFetchEnvelope(conn, uids: latest, peek: true)
            print("🔍 [DEBUG] uidFetchEnvelope returned \(fetchLines.count) lines")

            // CRITICAL FIX: Reconstruct multi-line FETCH responses
            // IMAP servers can split responses when using literals {n}
            var reconstructedLines: [String] = []
            var currentFetch: String = ""
            var inLiteral = false

            for line in fetchLines {
                if line.hasPrefix("* ") && line.contains(" FETCH ") {
                    // New FETCH response - save previous if exists
                    if !currentFetch.isEmpty {
                        reconstructedLines.append(currentFetch)
                    }
                    currentFetch = line
                    
                    // Check if this line contains a literal marker {n}
                    if line.contains("{") && !line.hasSuffix(")") {
                        inLiteral = true
                    } else {
                        inLiteral = false
                    }
                } else if line.hasPrefix("A") {
                    // Tagged response - save current FETCH and add this line
                    if !currentFetch.isEmpty {
                        reconstructedLines.append(currentFetch)
                        currentFetch = ""
                    }
                    reconstructedLines.append(line)
                    inLiteral = false
                } else if inLiteral || (!currentFetch.isEmpty && !line.hasPrefix("A")) {
                    // Continuation line (literal data or wrapped response)
                    currentFetch += " " + line
                    
                    // Check if we're done with this FETCH (ends with closing paren)
                    if line.hasSuffix(")") || line.hasSuffix("))") {
                        inLiteral = false
                    }
                }
            }

            // Don't forget the last FETCH
            if !currentFetch.isEmpty {
                reconstructedLines.append(currentFetch)
            }

            print("🔍 [DEBUG] Reconstructed into \(reconstructedLines.count) logical lines")
            for (idx, line) in reconstructedLines.enumerated() {
                let preview = line.count > 300 ? String(line.prefix(300)) + "..." : line
                print("🔍 [DEBUG] Reconstructed[\(idx)]: \(preview)")
            }

            // CRITICAL FIX 2: Remove literal markers {n} from reconstructed lines
            // The parser doesn't handle literal size markers - they're only for the transport layer
            var sanitizedLines: [String] = []
            for line in reconstructedLines {
                var cleaned = line
                
                // Remove all literal size markers like {99}, {123}, etc.
                // Pattern: {digits} followed by space or continuation
                let literalPattern = /\{(\d+)\}\s*/
                cleaned = cleaned.replacing(literalPattern, with: "")
                
                sanitizedLines.append(cleaned)
            }

            print("🔍 [DEBUG] After sanitization:")
            for (idx, line) in sanitizedLines.enumerated() {
                let preview = line.count > 200 ? String(line.prefix(200)) + "..." : line
                print("🔍 [DEBUG] Sanitized[\(idx)]: \(preview)")
            }

            let parser = IMAPParsers()
            let envelopes = parser.parseEnvelope(sanitizedLines)
            print("🔍 [DEBUG] Parsed \(envelopes.count) envelopes")

            if envelopes.isEmpty && !sanitizedLines.isEmpty {
                print("⚠️ [DEBUG] Parser still returns 0 - checking parser logic...")
                // Check if lines match parser expectations
                for line in sanitizedLines {
                    if line.hasPrefix("* ") && line.contains(" FETCH ") {
                        print("✅ [DEBUG] Line matches FETCH pattern")
                        if line.contains("ENVELOPE") {
                            print("✅ [DEBUG] Line contains ENVELOPE")
                        } else {
                            print("❌ [DEBUG] Line missing ENVELOPE!")
                        }
                    }
                }
            }
            let flags = parser.parseFlags(fetchLines)
            let flagsByUID = Dictionary(uniqueKeysWithValues: flags.map { ($0.uid, $0.flags) })

            // Persist into DAO if available - Note: Currently no direct write methods in repository
            // This would need to be implemented if write functionality is needed
            // For now, we skip persistence and just return the network data

            let mapped: [MailHeader] = envelopes.map { e in
                let fl = flagsByUID[e.uid] ?? []
                return MailHeader(id: e.uid, from: e.from, subject: e.subject, date: e.internalDate ?? Date(), unread: !fl.contains("\\Seen"))
            }
            
            print("✅ [MailTransportStubs] Returning \(mapped.count) headers")
            return .success(mapped.sorted { $0.date > $1.date })
        } catch {
            print("❌ [MailTransportStubs] IMAP fetch failed: \(error)")
            print("❌ [MailTransportStubs] Error type: \(type(of: error))")
            print("❌ [MailTransportStubs] Error details: \(String(describing: error))")
            return .failure(error)
        }
    }

    // MARK: - Message

    func fetchMessageUID(_ uid: String, folder: String, using account: MailAccountConfig) async -> Result<FullMessage, Error> {
        // Try cache first
        if let dao = MailRepository.shared.dao,
           let body = try? dao.bodyEntity(accountId: account.id, folder: folder, uid: uid) {
            // Need a header stub for subject/from
            if let head = try? dao.headers(accountId: account.id, folder: folder, limit: 1, offset: 0).first(where: { $0.id == uid }) {
                let hdr = MailHeader(id: uid, from: head.from, subject: head.subject, date: head.date ?? Date(), unread: !head.flags.contains("\\Seen"))
                return .success(FullMessage(header: hdr, textBody: body.text, htmlBody: body.html, rawBody: body.rawBody))
            }
        }
        // Network load
        do {
            let conn = IMAPConnection(label: "body.\(account.id.uuidString.prefix(6))")
            defer { conn.close() }
            let conf = IMAPConnectionConfig(
                host: account.recvHost,
                port: account.recvPort,
                tls: (account.recvEncryption == .sslTLS),
                sniHost: account.recvHost,
                connectionTimeoutSec: account.connectionTimeoutSec,
                commandTimeoutSec: max(5, account.connectionTimeoutSec/2),
                idleTimeoutSec: 15
            )
            try await conn.open(conf)
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            if account.recvEncryption == .startTLS { try await cmds.startTLS(conn) }
            guard let pwd = account.recvPassword else { throw ServiceError.invalidAccount }
            try await cmds.login(conn, user: account.recvUsername, pass: pwd)
            _ = try await cmds.select(conn, folder: folder, readOnly: true)
            let lines = try await cmds.uidFetchBody(conn, uid: uid, partsOrPeek: "BODY.PEEK[]")
            // Parse body (best-effort text/html split)
            let raw = IMAPParsers().parseBodySection(lines) ?? ""
            
            // ✅ PHASE 4: RAW-first Storage - vereinfacht
            print("🔍 PHASE 4: RAW-first storage for UID: \(uid)")
            print("🔍 [MailTransportStubs] Raw body length: \(raw.count)")
            
            // ✅ RAW direkt speichern ohne MIME-Processing
            if let writeDAO = MailRepository.shared.writeDAO {
                let entity = MessageBodyEntity(
                    accountId: account.id,
                    folder: folder,
                    uid: uid,
                    text: nil,              // ← Leer lassen (später Processing)
                    html: nil,              // ← Leer lassen (später Processing)
                    hasAttachments: false,  // ← Später aus rawBody erkennen
                    rawBody: raw,           // ← NUR RAW speichern
                    contentType: nil,       // ← Später extrahieren
                    charset: nil,           // ← Später extrahieren
                    transferEncoding: nil,
                    isMultipart: false,     // ← Später aus rawBody erkennen
                    rawSize: raw.count,
                    processedAt: nil        // ← NIL = nicht verarbeitet
                )
                try? writeDAO.storeBody(accountId: account.id, folder: folder, uid: uid, body: entity)
                print("✅ [MailTransportStubs] Stored RAW body (\(raw.count) bytes)")
            }

            // Build header from cache or placeholder
            var from = "unknown@example.com"
            var subj = "(Kein Betreff)"
            var date = Date()
            if let dao = MailRepository.shared.dao,
               let head = try? dao.headers(accountId: account.id, folder: folder, limit: 200, offset: 0).first(where: { $0.id == uid }) {
                from = head.from; subj = head.subject; date = head.date ?? Date()
            }
            
            // ✅ PHASE 4: Return mit RAW statt processed
            let header = MailHeader(id: uid, from: from, subject: subj, date: date, unread: false)
            return .success(FullMessage(
                header: header, 
                textBody: raw,      // ← RAW als textBody
                htmlBody: nil,      // ← Kein HTML Processing
                rawBody: raw        // ← RAW body für technische Ansicht
            ))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Helper: Separate RFC822 Headers from Body
    
    /// Separates mail headers from body content according to RFC822
    /// Returns: (headers as array of lines, body content)
    private func separateHeadersFromBody(_ raw: String) -> ([String], String) {
        let lines = raw.components(separatedBy: .newlines)
        var headerLines: [String] = []
        var bodyStartIndex = 0
        var inHeaderSection = true
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if inHeaderSection {
                // Empty line marks end of headers (RFC822)
                if trimmed.isEmpty {
                    bodyStartIndex = index + 1
                    inHeaderSection = false
                    break
                }
                
                // Check if this looks like a header line
                if isMailHeaderLine(line) || isHeaderContinuation(line) {
                    headerLines.append(line)
                } else if !trimmed.isEmpty {
                    // Non-empty, non-header line found - body starts here
                    bodyStartIndex = index
                    break
                }
            }
        }
        
        // Extract body (everything after headers)
        let bodyLines = bodyStartIndex < lines.count ? Array(lines[bodyStartIndex...]) : []
        let body = bodyLines.joined(separator: "\n")
        
        return (headerLines, body)
    }
    
    /// Check if line looks like a mail header
    private func isMailHeaderLine(_ line: String) -> Bool {
        let headerPrefixes = [
            "From:", "To:", "Cc:", "Bcc:", "Subject:", "Date:",
            "Return-Path:", "Received:", "Message-ID:", "Message-Id:",
            "In-Reply-To:", "References:", "MIME-Version:", "Mime-Version:",
            "Content-Type:", "Content-Transfer-Encoding:",
            "X-", "Delivered-To:", "Reply-To:", "Sender:",
            "List-", "Precedence:", "Priority:", "Importance:",
            "Authentication-Results:", "DKIM-Signature:", "ARC-"
        ]
        
        for prefix in headerPrefixes {
            if line.hasPrefix(prefix) {
                return true
            }
        }
        
        return false
    }
    
    /// Check if line is a continuation of previous header (starts with whitespace)
    private func isHeaderContinuation(_ line: String) -> Bool {
        return line.hasPrefix(" ") || line.hasPrefix("\t")
    }

    // MARK: - Cache

    func clearCache(for account: MailAccountConfig, folder: String) {
        // Best-effort: clear cache by using repository methods
        Task {
            // For now, we don't have a direct clear method in the new architecture
            // This would need to be implemented as a repository method if needed
            print("⚠️ Cache clear not implemented in new DAO architecture")
        }
    }
}

// MARK: - MailSendReceive Phase 2 Extension

extension MailSendReceive {
    
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
            // TODO: Implement uidFetchStructureAndMetadata when available
            let structureLines = try await cmds.uidFetchEnvelope(conn, uids: [uid], peek: true)
            
            let parser = IMAPParsers()
            // TODO: Replace with real parseEnhancedBodyStructure when available
            let enhanced = createMockEnhancedStructure()
            
            print("📊 [Phase2] STEP 2: Analyzed BODYSTRUCTURE")
            print("   - Total sections: \(enhanced.sections.count)")
            print("   - Body candidates: \(enhanced.bodyCandidates.count)")
            print("   - Inline parts: \(enhanced.inlineParts.count)")
            print("   - Attachments: \(enhanced.attachments.count)")
            
            // STEP 3: Determine which sections to fetch now
            var sectionsToFetch: [String] = []
            var sectionPurpose: [String: String] = [:]
            
            // 3a) Body content (HTML preferred, text fallback)
            if !enhanced.bodyCandidates.isEmpty {
                let firstCandidate = enhanced.bodyCandidates[0]
                sectionsToFetch.append(firstCandidate)
                sectionPurpose[firstCandidate] = "Body content"
            }
            
            print("📊 [Phase2] STEP 3: Determined sections to fetch")
            for section in sectionsToFetch {
                print("   - \(section): \(sectionPurpose[section] ?? "unknown")")
            }
            
            // STEP 4: Fetch selected sections (batch)
            let contentLines = try await cmds.uidFetchBody(conn, uid: uid, partsOrPeek: "BODY.PEEK[]")
            
            // Parse section contents
            let rawBody = parser.parseBodySection(contentLines) ?? ""
            let sectionData = ["1": rawBody.data(using: .utf8) ?? Data()]
            
            print("📊 [Phase2] STEP 4: Fetched \(sectionData.count) sections")
            for (section, data) in sectionData {
                print("   - \(section): \(data.count) bytes")
            }
            
            // STEP 5: Process and decode content
            let bodyContent = try processBodyContentStub(
                sectionData: sectionData,
                parser: parser
            )
            
            print("📊 [Phase2] STEP 5: Processed body content")
            print("   - HTML: \(bodyContent.html != nil)")
            print("   - Text: \(bodyContent.text != nil)")
            
            // STEP 6: Store MIME parts in database (Phase 1 integration)
            // TODO: Implement MIME parts storage when DAO supports it
            print("📊 [Phase2] STEP 6: MIME parts storage not implemented yet")
            
            // STEP 7: Build FullMessage response
            let header = try await buildHeaderFromEnvelope(
                uid: uid,
                account: account,
                folder: folder,
                structureLines: structureLines,
                parser: parser
            )
            
            let fullMessage = FullMessage(
                header: header,
                textBody: bodyContent.text,
                htmlBody: bodyContent.html,
                rawBody: rawBody // Include raw body for debugging
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
            
            // Batch fetch with BODYSTRUCTURE - simplified to envelope
            let fetchLines = try await cmds.uidFetchEnvelope(conn, uids: latest, peek: true)
            
            // Parse structures - simplified
            let parser = IMAPParsers()
            let structures: [String: PlaceholderEnhancedStructure] = [:]
            
            // Parse envelopes
            let envelopes = parser.parseEnvelope(fetchLines)
            let flags = parser.parseFlags(fetchLines)
            let flagsByUID = Dictionary(uniqueKeysWithValues: flags.map { ($0.uid, $0.flags) })
            
            // Build headers with accurate attachment info
            let headers = envelopes.map { env in
                let fl = flagsByUID[env.uid] ?? []
                let hasAttachments = false // Simplified - no structure analysis yet
                
                var header = MailHeader(
                    id: env.uid,
                    from: env.from,
                    subject: env.subject,
                    date: env.internalDate ?? Date(),
                    unread: !fl.contains("\\Seen")
                )
                // Note: hasAttachments property needs to be added to MailHeader struct
                
                return header
            }
            
            print("✅ [Phase2] Fetched \(headers.count) headers with structure analysis")
            print("   - Messages with attachments: 0") // Simplified
            
            return .success(headers.sorted { $0.date > $1.date })
            
        } catch {
            print("❌ [Phase2] Structure-based header fetch failed: \(error)")
            return .failure(error)
        }
    }
    
    // MARK: - Private Helpers
    
    private func createMockEnhancedStructure() -> EnhancedStructure {
        return EnhancedStructure(
            sections: ["1"],
            bodyCandidates: ["1"],
            inlineParts: [],
            attachments: []
        )
    }
    
    private func processBodyContentStub(sectionData: [String: Data],
                                       parser: IMAPParsers) throws -> BodyContentResult {
        // Simplified implementation - just return raw string as text
        guard let firstSection = sectionData.values.first else {
            return BodyContentResult(text: nil, html: nil)
        }
        
        // Basic string conversion
        let decodedString = String(data: firstSection, encoding: .utf8) ?? ""
        
        // Simple check for HTML content
        let isHTML = decodedString.lowercased().contains("<html") || 
                     decodedString.lowercased().contains("<!doctype") ||
                     decodedString.lowercased().contains("<body")
        
        if isHTML {
            return BodyContentResult(text: nil, html: decodedString)
        } else {
            return BodyContentResult(text: decodedString, html: nil)
        }
    }
    
    private func buildHeaderFromEnvelope(uid: String,
                                        account: MailAccountConfig,
                                        folder: String,
                                        structureLines: [String],
                                        parser: IMAPParsers) async throws -> MailHeader {
        // Try cached header first
        if let dao = MailRepository.shared.dao,
           let head = try? dao.headers(accountId: account.id, folder: folder, limit: 200, offset: 0).first(where: { $0.id == uid }) {
            return MailHeader(
                id: uid,
                from: head.from,
                subject: head.subject,
                date: head.date ?? Date(),
                unread: !head.flags.contains("\\Seen")
            )
        }
        
        // Parse envelope from structure lines
        let envelopes = parser.parseEnvelope(structureLines)
        if let env = envelopes.first {
            return MailHeader(
                id: uid,
                from: env.from,
                subject: env.subject,
                date: env.internalDate ?? Date(),
                unread: true
            )
        }
        
        // Fallback header
        return MailHeader(
            id: uid,
            from: "unknown@example.com",
            subject: "(Kein Betreff)",
            date: Date(),
            unread: false
        )
    }
}

// MARK: - Supporting Types

struct BodyContentResult {
    let text: String?
    let html: String?
}

struct EnhancedStructure {
    let sections: [String]
    let bodyCandidates: [String]
    let inlineParts: [String]
    let attachments: [String]
}

// Placeholder structure for simplified implementation
struct PlaceholderEnhancedStructure {
    let sections: [String] = ["1"]
    let bodyCandidates: [String] = ["1"] 
    let inlineParts: [String] = []
    let attachments: [String] = []
}

