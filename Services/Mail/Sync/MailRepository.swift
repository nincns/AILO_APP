// AILO_APP/Configuration/Services/Mail/MailRepository.swift
// Unified interface for UI and features to access mail data.
// Exposes high-level functions: listHeaders(), getBody(), sync(account:), send(message:).
// Internally uses specialized DAOs, MailSyncEngine, MailSendService, and FolderDiscoveryService.
// NOTE: This is the single entry point the UI should depend on.

import Foundation
import Combine
import SwiftUI
import SQLite3  // ✅ NEU - FÜR sqlite3_step und SQLITE_ROW

// MARK: - FolderMap Extension for DAO Compatibility

extension FolderMap {
    func toDictionary() -> [String: String] {
        var dict: [String: String] = [:]
        dict["inbox"] = self.inbox
        if !self.sent.isEmpty { dict["sent"] = self.sent }
        if !self.drafts.isEmpty { dict["drafts"] = self.drafts }
        if !self.trash.isEmpty { dict["trash"] = self.trash }
        if !self.spam.isEmpty { dict["spam"] = self.spam }
        return dict
    }
}

// MARK: - Repository models (lightweight)
public struct MailHeaderView: Sendable, Identifiable {
    public let id: String         // UID
    public let from: String
    public let subject: String
    public let date: Date?
    public let flags: [String]

    public init(id: String, from: String, subject: String, date: Date?, flags: [String]) {
        self.id = id
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}

public enum AccountHealth: String, Sendable {
    case ok, degraded, down
}

public enum RepositoryError: Error, LocalizedError {
    case accountNotFound
    case daoNotAvailable
    case networkError(String)
    
    public var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "Account configuration not found"
        case .daoNotAvailable:
            return "Database access not available"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - MailRepository

@MainActor
public final class MailRepository: ObservableObject {

    public static let shared = MailRepository()
    private init() {}

    // Dependencies (inject from composition root)
    public var dao: (any MailReadDAO)?        // For reading operations
    public var writeDAO: (any MailWriteDAO)?  // For writing operations
    public var factory: DAOFactory? // Store factory to keep it alive
    public var sendService: MailSendService = .shared
    
    // Sync protection
    private var isSyncing: Set<UUID> = []
    private let syncLock = NSLock()
    public var discovery: FolderDiscoveryService = .shared
    public var healthMetrics: MailMetrics = .shared

    // Internal subjects
    private let changeSubjectsQ = DispatchQueue(label: "mail.repo.changes.queue")
    private var changeSubjects: [UUID: PassthroughSubject<Void, Never>] = [:]

    // MARK: - Public API (UI should use these)

    // Lesen
    public func listHeaders(accountId: UUID, folder: String, limit: Int = 50, offset: Int = 0) throws -> [MailHeader] {
        guard let dao else { return [] }
        return try dao.headers(accountId: accountId, folder: folder, limit: limit, offset: offset)
    }

    public func getBody(accountId: UUID, folder: String, uid: String) throws -> String? {
        guard let dao = dao else { return nil }
        return try dao.body(accountId: accountId, folder: folder, uid: uid)
    }

    /// 1.1 Alle konfigurierten SpecialFolders abrufen
    public func getAllConfiguredFolders(accountId: UUID) -> [String] {
        print("📁 getAllConfiguredFolders for account: \(accountId)")
        
        let key = "mail.accounts"
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let account = list.first(where: { $0.id == accountId }) else {
            print("❌ Account not found, returning INBOX only")
            return ["INBOX"]
        }
        
        var folders: [String] = []
        
        // WICHTIG: Trim alle Ordnernamen!
        let inbox = account.folders.inbox.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inbox.isEmpty {
            folders.append(inbox)
        }
        
        let sent = account.folders.sent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sent.isEmpty && !folders.contains(sent) {
            folders.append(sent)
        }
        
        let drafts = account.folders.drafts.trimmingCharacters(in: .whitespacesAndNewlines)
        if !drafts.isEmpty && !folders.contains(drafts) {
            folders.append(drafts)
        }
        
        let trash = account.folders.trash.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trash.isEmpty && !folders.contains(trash) {
            folders.append(trash)
        }
        
        let spam = account.folders.spam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spam.isEmpty && !folders.contains(spam) {
            folders.append(spam)
        }
        
        print("📁 Configured folders from account (trimmed): \(folders)")
        return folders
    }

    /// 1.2 Alle Server-Ordner via IMAP LIST abrufen
    public func getAllServerFolders(accountId: UUID) async -> Result<[String], Error> {
        print("🌐 getAllServerFolders for account: \(accountId)")
        
        do {
            // Account-Konfiguration laden
            let account = try loadAccountConfig(accountId: accountId)
            print("🌐 Loaded account config: \(account.accountName)")
            
            // IMAP-Verbindung aufbauen
            let conn = IMAPConnection(label: "folders.\(accountId.uuidString.prefix(6))")
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
            
            print("🌐 Opening connection to \(conf.host):\(conf.port)")
            try await conn.open(conf)
            
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            
            if account.recvEncryption == .startTLS {
                try await cmds.startTLS(conn)
            }
            
            guard let pwd = account.recvPassword else {
                throw RepositoryError.accountNotFound
            }
            
            try await cmds.login(conn, user: account.recvUsername, pass: pwd)
            
            // LIST-Befehl ausführen
            print("🌐 Executing LIST command...")
            let listLines = try await cmds.listAll(conn, idleTimeout: 10.0)
            
            // Ordnernamen aus LIST-Response extrahieren
            let parser = IMAPParsers()
            var folderNames: [String] = []
            
            for line in listLines {
                if let folderInfo = try? parser.parseListResponse(line) {
                    folderNames.append(folderInfo.name)
                }
            }
            
            print("🌐 Found \(folderNames.count) folders on server: \(folderNames)")
            return .success(folderNames)
            
        } catch {
            print("❌ Failed to get server folders: \(error)")
            return .failure(error)
        }
    }

    // MARK: - Folder Management

    // Sync
    public func sync(accountId: UUID, folders: [String]? = nil) {
        print("🔥 MailRepository.sync() called for account: \(accountId)")
        let folderList = folders ?? getAllConfiguredFolders(accountId: accountId)
        print("🔥 Folders to sync: \(folderList)")

        // Check if this should be initial or incremental sync
        for folderName in folderList {
            do {
                let existingHeaders = try listHeaders(accountId: accountId, folder: folderName, limit: 1)

                if existingHeaders.isEmpty {
                    print("📊 Database is empty for folder \(folderName) - performing initial sync")
                    performInitialSync(accountId: accountId, folders: [folderName])
                } else {
                    print("🔥 Database has existing data for folder \(folderName) - performing full refresh")
                    performFullRefreshSync(accountId: accountId, folders: [folderName])
                }
            } catch {
                print("❌ Error checking local headers for \(folderName): \(error)")
                // Fallback to initial sync if we can't check local state
                performInitialSync(accountId: accountId, folders: [folderName])
            }
        }
        
        print("🔥 Sync strategy determined and initiated")
    }

    /// Sync ALL messages from server (no limit) - use with caution for large mailboxes
    public func syncAll(accountId: UUID, folders: [String]? = nil) {
        print("🚀 MailRepository.syncAll() called for account: \(accountId)")
        let folderList = folders ?? getAllConfiguredFolders(accountId: accountId)
        print("🚀 Syncing ALL messages in folders: \(folderList)")

        for folderName in folderList {
            performUnlimitedSync(accountId: accountId, folder: folderName)
        }
    }

    /// Perform unlimited sync - fetches ALL messages from server
    private func performUnlimitedSync(accountId: UUID, folder: String) {
        print("🚀 Performing UNLIMITED sync for folder: \(folder)")

        Task {
            do {
                let account: MailAccountConfig
                do {
                    account = try loadAccountConfig(accountId: accountId)
                    print("🚀 [SyncAll] Account: \(account.accountName)")
                } catch {
                    print("❌ Failed to load account config: \(error)")
                    await MainActor.run { self.publishChange(accountId) }
                    return
                }

                let transport = MailSendReceive()
                // Sehr hoher Limit-Wert für "alle" Mails (10000 sollte für die meisten Postfächer reichen)
                let unlimitedLimit = 10000

                print("🚀 Fetching up to \(unlimitedLimit) messages from \(folder)...")

                let result = await transport.fetchHeaders(
                    limit: unlimitedLimit,
                    folder: folder,
                    using: account,
                    preferCache: false,
                    force: true
                )

                switch result {
                case .success(let headers):
                    print("✅ [SyncAll] Fetched \(headers.count) headers from: \(folder)")

                    let domainHeaders = headers.map { transportHeader in
                        MailHeader(
                            id: transportHeader.id,
                            from: transportHeader.from,
                            subject: transportHeader.subject,
                            date: transportHeader.date,
                            flags: transportHeader.unread ? [] : ["\\Seen"]
                        )
                    }

                    if !domainHeaders.isEmpty {
                        try? writeDAO?.upsertHeaders(accountId: accountId, folder: folder, headers: domainHeaders)
                        print("✅ [SyncAll] Saved \(domainHeaders.count) headers to database")
                    }

                    await MainActor.run { self.publishChange(accountId) }

                case .failure(let error):
                    print("❌ [SyncAll] Failed to fetch headers: \(error)")
                    await MainActor.run { self.publishChange(accountId) }
                }
            } catch {
                print("❌ [SyncAll] Error: \(error)")
                await MainActor.run { self.publishChange(accountId) }
            }
        }
    }

    /// Perform full refresh sync - re-fetches and reconciles all messages
    private func performFullRefreshSync(accountId: UUID, folders: [String]) {
        print("🔄 Performing full refresh sync for account: \(accountId), folders: \(folders)")
        
        Task {
            do {
                print("🔄 Starting REAL full refresh IMAP sync...")
                
                // Get account configuration
                let account: MailAccountConfig
                do {
                    account = try loadAccountConfig(accountId: accountId)
                } catch {
                    print("❌ Failed to load account config: \(error)")
                    await MainActor.run {
                        self.publishChange(accountId)
                    }
                    return
                }
                
                // Use MailSendReceive to fetch headers for each folder
                let transport = MailSendReceive()
                var totalNewHeaders = 0
                
                for folder in folders {
                    print("🔄 Full refresh syncing folder: \(folder) (limit: \(account.syncLimitRefresh))")

                    let result = await transport.fetchHeaders(
                        limit: account.syncLimitRefresh,
                        folder: folder,
                        using: account,
                        preferCache: false, // Force network fetch for full refresh
                        force: true
                    )
                    
                    switch result {
                    case .success(let headers):
                        print("✅ Fetched \(headers.count) headers from folder: \(folder)")
                        totalNewHeaders += headers.count
                        
                        // Convert MailSendReceive.MailHeader to Domain MailHeader
                        let domainHeaders = headers.map { transportHeader in
                            MailHeader(
                                id: transportHeader.id,
                                from: transportHeader.from,
                                subject: transportHeader.subject,
                                date: transportHeader.date,
                                flags: transportHeader.unread ? [] : ["\\Seen"]
                            )
                        }
                        
                        // Save to database if we have DAO
                        if let writeDAO = self.writeDAO {
                            try writeDAO.upsertHeaders(accountId: accountId, folder: folder, headers: domainHeaders)
                            print("✅ Saved \(domainHeaders.count) headers to database for folder: \(folder)")
                        }
                        
                        // 🆕 Fetch bodies for all messages
                        let uidsToFetch = domainHeaders.map { $0.id }
                        await fetchBodiesInBatch(accountId: accountId, folder: folder, uids: uidsToFetch, account: account)
                        
                    case .failure(let error):
                        print("❌ Failed to fetch headers from folder \(folder): \(error)")
                    }
                }
                
                print("✅ Full refresh sync completed - fetched \(totalNewHeaders) total headers")
                
                // Notify UI that data changed
                await MainActor.run {
                    self.publishChange(accountId)
                }
                
            } catch {
                print("❌ Full refresh sync failed: \(error)")
            }
        }
    }

    /// Perform incremental sync - only fetches new messages from server
    /// If local database is empty, automatically performs initial full sync instead
    public func incrementalSync(accountId: UUID, folders: [String]? = nil) {
        print("📈 MailRepository.incrementalSync() called for account: \(accountId)")
        
        // Prüfe ob bereits am syncen
        syncLock.lock()
        if isSyncing.contains(accountId) {
            print("⚠️ Sync already running for account \(accountId), skipping...")
            syncLock.unlock()
            return
        }
        isSyncing.insert(accountId)
        syncLock.unlock()
        
        let folderList = folders ?? getAllConfiguredFolders(accountId: accountId)
        
        // Check if we need initial sync vs incremental sync
        for folderName in folderList {
            do {
                let existingHeaders = try listHeaders(accountId: accountId, folder: folderName, limit: 1)
                
                if existingHeaders.isEmpty {
                    print("📊 Database is empty for folder \(folderName) - performing initial full sync")
                    performInitialSync(accountId: accountId, folders: [folderName])
                } else {
                    print("📈 Performing incremental sync for folder \(folderName) (existing: \(existingHeaders.count) headers)")
                    performIncrementalSync(accountId: accountId, folders: [folderName])
                }
            } catch {
                print("❌ Error checking local headers for \(folderName): \(error)")
                // Fallback to initial sync if we can't check local state
                performInitialSync(accountId: accountId, folders: [folderName])
            }
        }
        
        print("📈 Sync strategy determined and initiated")
        
        // Sync lock nach 3 Sekunden freigeben
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncLock.lock()
            isSyncing.remove(accountId)
            syncLock.unlock()
        }
    }
    
    /// Perform initial full sync - fetches all messages from server
    private func performInitialSync(accountId: UUID, folders: [String]) {
        print("🔄 Performing initial full sync for account: \(accountId), folders: \(folders)")
        
        Task {
            do {
                print("🔄 Starting REAL IMAP sync...")
                
                // Get account configuration
                let account: MailAccountConfig
                do {
                    account = try loadAccountConfig(accountId: accountId)
                } catch {
                    print("❌ Failed to load account config: \(error)")
                    await MainActor.run {
                        self.publishChange(accountId)
                    }
                    return
                }
                
                // Use MailTransportStubs to fetch headers for each folder
                let transport = MailSendReceive()
                var totalNewHeaders = 0
                
                for folder in folders {
                    print("🔄 Syncing folder: \(folder)")
                    print("🔧 [MailRepository] About to call fetchHeaders...")
                    print("🔧 [MailRepository] Account - host: \(account.recvHost), port: \(account.recvPort)")
                    print("🔧 [MailRepository] preferCache: false, force: true, limit: \(account.syncLimitInitial)")

                    let result = await transport.fetchHeaders(
                        limit: account.syncLimitInitial,
                        folder: folder,
                        using: account,
                        preferCache: false, // Force network fetch for initial sync
                        force: true
                    )
                    
                    print("🔧 [MailRepository] fetchHeaders returned!")
                    
                    switch result {
                    case .success(let headers):
                        print("✅ Fetched \(headers.count) headers from folder: \(folder)")
                        
                        if headers.isEmpty {
                            print("⚠️ WARNING: fetchHeaders returned SUCCESS but with 0 headers!")
                        }
                        
                        totalNewHeaders += headers.count
                        
                        // Convert MailSendReceive.MailHeader to Domain MailHeader
                        let domainHeaders = headers.map { transportHeader in
                            MailHeader(
                                id: transportHeader.id,
                                from: transportHeader.from,
                                subject: transportHeader.subject,
                                date: transportHeader.date,
                                flags: transportHeader.unread ? [] : ["\\Seen"]
                            )
                        }
                        
                        // Save to database if we have DAO
                        if let writeDAO = self.writeDAO {
                            try writeDAO.upsertHeaders(accountId: accountId, folder: folder, headers: domainHeaders)
                            print("✅ Saved \(domainHeaders.count) headers to database for folder: \(folder)")
                        }
                        
                        // 🆕 Fetch bodies for all new messages
                        let uidsToFetch = domainHeaders.map { $0.id }
                        await fetchBodiesInBatch(accountId: accountId, folder: folder, uids: uidsToFetch, account: account)
                        
                    case .failure(let error):
                        print("❌ Failed to fetch headers from folder \(folder): \(error)")
                    }
                }
                
                print("✅ Initial sync completed - fetched \(totalNewHeaders) total headers")
                
                // Notify UI that data changed
                await MainActor.run {
                    self.publishChange(accountId)
                }
                
            } catch {
                print("❌ Initial sync failed: \(error)")
            }
        }
    }
    
    /// Perform incremental sync - only new messages since last sync
    private func performIncrementalSync(accountId: UUID, folders: [String]) {
        print("📈 Performing incremental sync for account: \(accountId), folders: \(folders)")
        
        Task {
            do {
                print("📈 Starting REAL incremental IMAP sync...")
                
                // Get account configuration
                let account: MailAccountConfig
                do {
                    account = try loadAccountConfig(accountId: accountId)
                } catch {
                    print("❌ Failed to load account config: \(error)")
                    await MainActor.run {
                        self.publishChange(accountId)
                    }
                    return
                }
                
                // Use MailTransportStubs to fetch headers for each folder
                let transport = MailSendReceive()
                var totalNewHeaders = 0
                
                for folder in folders {
                    print("📈 Checking folder for new messages: \(folder) (limit: \(account.syncLimitIncremental))")

                    // For incremental sync, we prefer cache but force a refresh
                    let result = await transport.fetchHeaders(
                        limit: account.syncLimitIncremental,
                        folder: folder,
                        using: account,
                        preferCache: true, // Check cache first
                        force: true // But force network check anyway
                    )
                    
                    switch result {
                    case .success(let headers):
                        print("📈 Found \(headers.count) headers in folder: \(folder)")
                        
                        // Filter only truly new messages by checking against existing UIDs in database
                        let existingUIDs = Set((try? dao?.headers(accountId: accountId, folder: folder, limit: 1000, offset: 0))?.map { $0.id } ?? [])
                        let newHeaders = headers.filter { !existingUIDs.contains($0.id) }
                        
                        if !newHeaders.isEmpty {
                            totalNewHeaders += newHeaders.count
                            print("📈 Found \(newHeaders.count) NEW messages in folder: \(folder)")
                            
                            // Convert and save new headers
                            let domainHeaders = newHeaders.map { transportHeader in
                                MailHeader(
                                    id: transportHeader.id,
                                    from: transportHeader.from,
                                    subject: transportHeader.subject,
                                    date: transportHeader.date,
                                    flags: transportHeader.unread ? [] : ["\\Seen"]
                                )
                            }
                            
                            // Save to database if we have DAO
                            if let writeDAO = self.writeDAO {
                                try writeDAO.upsertHeaders(accountId: accountId, folder: folder, headers: domainHeaders)
                                print("📈 Saved \(domainHeaders.count) new headers to database for folder: \(folder)")
                            }
                        } else {
                            print("📈 No new messages in folder: \(folder)")
                        }
                        
                    case .failure(let error):
                        print("❌ Failed to check folder \(folder) for new messages: \(error)")
                    }
                }
                
                if totalNewHeaders > 0 {
                    print("✅ Incremental sync completed - found \(totalNewHeaders) new headers")
                } else {
                    print("✅ Incremental sync completed - no new messages")
                }
                
                // Notify UI that data changed
                await MainActor.run {
                    self.publishChange(accountId)
                }
                
            } catch {
                print("❌ Incremental sync failed: \(error)")
                await MainActor.run {
                    self.publishChange(accountId)
                }
            }
        }
    }

    // MARK: - Body Fetching

    /// Fetch and store body for a specific message
    private func fetchAndStoreBody(accountId: UUID, folder: String, uid: String, account: MailAccountConfig) async {
        print("📥 Fetching body for UID: \(uid) in folder: \(folder)")

        do {
            let transport = MailSendReceive()

            // Fetch full message (includes body)
            let result = await transport.fetchMessageUID(uid, folder: folder, using: account)

            switch result {
            case .success(let fullMessage):
                let rawBody = fullMessage.rawBody ?? ""

                guard !rawBody.isEmpty else {
                    print("⚠️ Fetched rawBody is empty for UID: \(uid)")
                    return
                }

                print("✅ Fetched rawBody for UID: \(uid) - size: \(rawBody.count) bytes")

                // ✅ RAW-first Storage mit Anhang-Erkennung
                let hasAttachments = detectAttachments(in: rawBody)
                let isMultipart = rawBody.lowercased().contains("content-type: multipart/")
                let contentType = extractContentType(from: rawBody)

                if hasAttachments {
                    print("📎 [MailRepository] Detected attachments in UID: \(uid)")
                }

                let bodyEntity = MessageBodyEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: uid,
                    text: nil,              // ← Leer lassen (später Processing)
                    html: nil,              // ← Leer lassen (später Processing)
                    hasAttachments: hasAttachments,  // ✅ Aus rawBody erkannt
                    rawBody: rawBody,       // ← NUR RAW speichern
                    contentType: contentType,
                    charset: extractCharset(from: rawBody),
                    transferEncoding: nil,
                    isMultipart: isMultipart,  // ✅ Aus rawBody erkannt
                    rawSize: rawBody.count,
                    processedAt: nil        // ← NIL = nicht verarbeitet
                )

                // Store in database
                if let writeDAO = self.writeDAO {
                    try writeDAO.storeBody(accountId: accountId, folder: folder, uid: uid, body: bodyEntity)
                    print("✅ [MailRepository] Stored RAW body for UID: \(uid) - size: \(rawBody.count) bytes")
                }

                // 📎 NEU: Anhänge extrahieren und in Datenbank speichern
                if hasAttachments {
                    await extractAndStoreAttachments(accountId: accountId, folder: folder, uid: uid, rawBody: rawBody)
                }

            case .failure(let error):
                print("❌ Failed to fetch body for UID: \(uid): \(error)")
            }

        } catch {
            print("❌ Error fetching/storing body for UID: \(uid): \(error)")
        }
    }

    /// Extrahiert Anhänge aus rawBody und speichert sie in der Datenbank
    private func extractAndStoreAttachments(accountId: UUID, folder: String, uid: String, rawBody: String) async {
        print("📎 [MailRepository] Extracting attachments for UID: \(uid)")

        // Nutze den zentralen AttachmentExtractor
        let extracted = AttachmentExtractor.extract(from: rawBody)

        guard !extracted.isEmpty else {
            print("📎 [MailRepository] No attachments extracted for UID: \(uid)")
            return
        }

        print("📎 [MailRepository] Extracted \(extracted.count) attachment(s)")

        // Konvertiere zu AttachmentEntity und speichere
        var attachmentEntities: [AttachmentEntity] = []

        for (index, attachment) in extracted.enumerated() {
            let entity = AttachmentEntity(
                accountId: accountId,
                folder: folder,
                uid: uid,
                partId: "part\(index + 1)",
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                sizeBytes: attachment.data.count,
                data: attachment.data,
                contentId: attachment.contentId,
                isInline: attachment.contentId != nil
            )
            attachmentEntities.append(entity)
            print("📎 [MailRepository] Created entity: \(attachment.filename) (\(attachment.data.count) bytes)")
        }

        // Speichere alle Anhänge
        storeAttachments(accountId: accountId, folder: folder, uid: uid, attachments: attachmentEntities)
        print("✅ [MailRepository] Stored \(attachmentEntities.count) attachment(s) for UID: \(uid)")
    }

    /// Fetch bodies for multiple messages in parallel (with rate limiting)
    private func fetchBodiesInBatch(accountId: UUID, folder: String, uids: [String], account: MailAccountConfig) async {
        print("📥 Fetching bodies for \(uids.count) messages in batches...")
        
        // Process in batches of 5 to avoid overwhelming the server
        let batchSize = 5
        for batchIndex in stride(from: 0, to: uids.count, by: batchSize) {
            let batchEnd = min(batchIndex + batchSize, uids.count)
            let batch = Array(uids[batchIndex..<batchEnd])
            
            print("📦 Processing batch \(batchIndex/batchSize + 1) (\(batch.count) messages)...")
            
            // Fetch bodies in parallel within batch
            await withTaskGroup(of: Void.self) { group in
                for uid in batch {
                    group.addTask {
                        await self.fetchAndStoreBody(accountId: accountId, folder: folder, uid: uid, account: account)
                    }
                }
            }
            
            // Small delay between batches to be nice to the server
            if batchEnd < uids.count {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
        
        print("✅ All bodies fetched and stored for folder: \(folder)")
    }


    /// Load cached headers immediately from local storage without any network operations
    public func loadCachedHeaders(accountId: UUID, folder: String, limit: Int = 100, offset: Int = 0) throws -> [MailHeader] {
        guard let dao else { return [] }
        print("📱 Loading cached headers from local storage...")
        return try dao.headers(accountId: accountId, folder: folder, limit: limit, offset: offset)
    }
    
    /// Load cached mail body immediately from local storage without any network operations
    public func loadCachedBody(accountId: UUID, folder: String, uid: String) throws -> String? {
        guard let dao = dao else { return nil }
        print("📱 Loading cached mail body from local storage...")
        return try dao.body(accountId: accountId, folder: folder, uid: uid)
    }

    /// Fetch body for a single message on-demand
    public func fetchBodyOnDemand(accountId: UUID, folder: String, uid: String) async throws {
        print("📥 On-demand body fetch for UID: \(uid)")
        
        let account = try loadAccountConfig(accountId: accountId)
        await fetchAndStoreBody(accountId: accountId, folder: folder, uid: uid, account: account)
    }

    // MARK: - Attachment Storage (CRITICAL FIX)

    /// Store attachments extracted from mail processing
    public func storeAttachments(accountId: UUID, folder: String, uid: String, attachments: [AttachmentEntity]) {
        guard !attachments.isEmpty, let writeDAO = writeDAO else {
            print("❌ Cannot store attachments - no writeDAO or empty list")
            return
        }
        
        print("📎 [MailRepository] Storing \(attachments.count) attachments for UID: \(uid)")
        
        for attachment in attachments {
            do {
                try writeDAO.storeAttachment(
                    accountId: accountId,
                    folder: folder,
                    uid: uid,
                    attachment: attachment
                )
                print("✅ [MailRepository] Stored attachment: \(attachment.filename)")
            } catch {
                print("❌ [MailRepository] Failed to store attachment \(attachment.filename): \(error)")
            }
        }
        
        // Update has_attachments flag in message_body
        if writeDAO != nil {
            // TODO: Update message_body.has_attachments = 1
            print("✅ [MailRepository] Updated has_attachments flag for UID: \(uid)")
        }
    }

    public func startBackgroundSync(accountId: UUID) {
        print("🔄 Starting background sync for account: \(accountId)")
        // TODO: Implement background sync startup logic
    }

    public func stopBackgroundSync(accountId: UUID) {
        print("⏹️ Stopping background sync for account: \(accountId)")
        // TODO: Implement background sync stop logic
    }

    public func specialFolders(accountId: UUID, login: FolderDiscoveryService.IMAPLogin? = nil) async -> [String: String]? {
        // 1) DAO cache
        if let dao = dao, let map = try? dao.specialFolders(accountId: accountId) {
            return map
        }
        // 2) Discovery (if login provided)
        guard let login else { return nil }
        let res = await discovery.discover(accountId: accountId, login: login)
        switch res {
        case .success(let folderMap):
            // Convert FolderMap to [String: String]
            let map = folderMap.toDictionary()
            try? dao?.saveSpecialFolders(accountId: accountId, map: map)
            return map
        case .failure:
            return nil
        }
    }

    // Senden
    @discardableResult
    public func send(_ draft: MailDraft, accountId: UUID) -> UUID {
        let id = sendService.queue(draft, accountId: accountId)
        publishChange(accountId)
        return id
    }

    // Health
    public func health(accountId: UUID) -> AccountHealth {
        let s = healthMetrics.summary(accountId: accountId, host: hostFor(accountId))
        switch s.health {
        case .ok: return .ok
        case .degraded: return .degraded
        case .down: return .down
        }
    }

    /// Emits whenever data potentially changed for this account (headers, flags, bodies, outbox, sync).
    public func onChanges(accountId: UUID) -> AnyPublisher<Void, Never> {
        changeSubjectsQ.sync {
            if let subj = changeSubjects[accountId] {
                return subj.eraseToAnyPublisher()
            } else {
                let s = PassthroughSubject<Void, Never>()
                changeSubjects[accountId] = s
                return s.eraseToAnyPublisher()
            }
        }
    }

    // Expose sync state to UI if desired
    public func publisherSyncState(accountId: UUID) -> AnyPublisher<SyncState, Never> {
        // TODO: Implement sync state tracking
        // For now, return a placeholder that emits idle state
        Just(SyncState.idle).eraseToAnyPublisher()
    }
    
    // Simple sync state enum for replacement
    public enum SyncState: Sendable {
        case idle, syncing, error(String)
    }

    public func publisherOutbox(accountId: UUID) -> AnyPublisher<[OutboxItem], Never> {
        sendService.publisherOutbox(accountId: accountId)
    }

    // MARK: - Helper Methods for IMAP Integration

    // MARK: - Helper Methods for IMAP Integration

    /// Load account configuration from UserDefaults
    private func loadAccountConfig(accountId: UUID) throws -> MailAccountConfig {
        let key = "mail.accounts"
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            print("❌ Failed to load accounts from UserDefaults")
            throw RepositoryError.accountNotFound
        }
        
        guard let account = accounts.first(where: { $0.id == accountId }) else {
            print("❌ Account not found: \(accountId)")
            throw RepositoryError.accountNotFound
        }
        
        print("✅ Loaded account: \(account.accountName) - \(account.recvHost)")
        return account
    }
    
    /// Lädt Attachment-Status für effiziente UI-Anzeige (OPTIMIERT)
    public func loadAttachmentStatus(accountId: UUID, folder: String) throws -> [String: Bool] {
        guard let dao = self.dao else {
            print("❌ No DAO available for loadAttachmentStatus")
            return [:]
        }

        print("📎 [OPTIMIZED] Loading attachment status for account: \(accountId), folder: \(folder)")

        do {
            let statusMap = try dao.attachmentStatus(accountId: accountId, folder: folder)
            print("📎 Loaded attachment status for \(statusMap.count) messages")
            let withAttachments = statusMap.values.filter { $0 }.count
            print("📎 → \(withAttachments) messages have attachments")
            return statusMap
        } catch {
            print("❌ Failed to load attachment status: \(error)")
            return [:]
        }
    }
    
    // MARK: - Wiring from outside (so repository can emit change signals)

    public func notifyDataChanged(accountId: UUID) {
        publishChange(accountId)
    }

    // You can connect these in composition root to forward sync/send events to the repo's change stream.
    public func attachDefaultForwarders(accountId: UUID) -> [AnyCancellable] {
        var bag: [AnyCancellable] = []
        
        // Sync state changes → trigger data change pings (lightweight)
        publisherSyncState(accountId: accountId).sink { [weak self] (state: SyncState) in
            self?.publishChange(accountId)
        }.store(in: &bag)
        
        // Outbox changes → trigger data change pings
        sendService.publisherOutbox(accountId: accountId).sink { [weak self] _ in
            self?.publishChange(accountId)
        }.store(in: &bag)
        
        // Health changes (optional)
        healthMetrics.publisherHealth(accountId: accountId).sink { [weak self] _ in
            self?.publishChange(accountId)
        }.store(in: &bag)
        
        return bag
    }

    // MARK: - Internals

    private func hostFor(_ accountId: UUID) -> String {
        // Load from persisted account config
        let key = "mail.accounts"
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
           let acc = list.first(where: { $0.id == accountId }) {
            return acc.recvHost
        }
        return "unknown-host"
    }

    private func publishChange(_ accountId: UUID) {
        changeSubjectsQ.sync {
            if let subj = changeSubjects[accountId] {
                subj.send(())
            } else {
                let s = PassthroughSubject<Void, Never>()
                changeSubjects[accountId] = s
                s.send(())
            }
        }
    }

    // MARK: - Attachment Detection Helpers

    /// Erkennt ob eine E-Mail Anhänge enthält basierend auf dem rawBody
    /// Hinweis: S/MIME Signaturdateien (.p7s) werden NICHT als Anhänge gezählt
    private func detectAttachments(in rawBody: String) -> Bool {
        let lowerBody = rawBody.lowercased()

        // 🔐 S/MIME-Only Check: Wenn NUR eine .p7s Signatur vorhanden ist, keine Anhänge
        // Prüfe ob es sich um multipart/signed mit nur Signatur handelt
        let isSignedOnly = lowerBody.contains("multipart/signed") &&
                           lowerBody.contains("pkcs7-signature") &&
                           !containsRealAttachment(lowerBody)

        if isSignedOnly {
            print("📎 [detectAttachments] Only S/MIME signature found, no real attachments")
            return false
        }

        // 1. Explizit als Attachment markiert (mit/ohne Leerzeichen nach Doppelpunkt)
        // Aber nicht für .p7s Dateien
        if (lowerBody.contains("content-disposition: attachment") ||
            lowerBody.contains("content-disposition:attachment")) &&
           !lowerBody.contains("smime.p7s") &&
           !lowerBody.contains("pkcs7-signature") {
            print("📎 [detectAttachments] Found via content-disposition: attachment")
            return true
        }

        // 2. Multipart/mixed enthält typischerweise Anhänge
        // Aber prüfen ob es echte Anhänge gibt (nicht nur Signatur)
        if lowerBody.contains("content-type: multipart/mixed") ||
           lowerBody.contains("content-type:multipart/mixed") {
            if containsRealAttachment(lowerBody) {
                print("📎 [detectAttachments] Found via multipart/mixed with real attachment")
                return true
            }
        }

        // 3. PDF, Office-Dokumente, etc. - robustere Erkennung
        let attachmentTypes = [
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats",
            "application/vnd.ms-excel",
            "application/vnd.ms-powerpoint",
            "application/zip",
            "application/x-zip",
            "application/x-zip-compressed",
            "application/octet-stream",
            "application/x-pdf",  // Alternative PDF MIME-Type
            "application/acrobat" // Älterer PDF MIME-Type
        ]
        for type in attachmentTypes {
            // Prüfe mit und ohne Leerzeichen nach Doppelpunkt
            if lowerBody.contains("content-type: \(type)") ||
               lowerBody.contains("content-type:\(type)") {
                print("📎 [detectAttachments] Found via content-type: \(type)")
                return true
            }
        }

        // 4. Dateiname mit typischen Anhang-Erweiterungen (ohne .p7s, .p7m, .p7c)
        let attachmentExtensions = [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
                                    ".zip", ".rar", ".7z", ".tar", ".gz"]
        for ext in attachmentExtensions {
            // Suche nach filename="xxx.pdf" oder name="xxx.pdf"
            if lowerBody.contains("filename=\"") || lowerBody.contains("name=\"") {
                // Regex-basierte Suche nach Dateiendung
                let patterns = [
                    "filename=\"[^\"]*\\\(ext)\"",
                    "filename=[^;\\s]*\\\(ext)",
                    "name=\"[^\"]*\\\(ext)\"",
                    "name=[^;\\s]*\\\(ext)"
                ]
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       regex.firstMatch(in: rawBody, range: NSRange(rawBody.startIndex..., in: rawBody)) != nil {
                        print("📎 [detectAttachments] Found via filename with extension: \(ext)")
                        return true
                    }
                }
            }
        }

        // 5. Generische filename= Erkennung (aber nicht für inline-Bilder und nicht für .p7s)
        if lowerBody.contains("filename=") && !lowerBody.contains("smime.p7s") {
            let lines = rawBody.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let lowerLine = line.lowercased()
                if lowerLine.contains("filename=") &&
                   !lowerLine.contains(".p7s") &&
                   !lowerLine.contains(".p7m") &&
                   !lowerLine.contains(".p7c") {
                    if index > 0 && index < lines.count {
                        let contextStart = max(0, index - 5)
                        let context = lines[contextStart...index].joined(separator: "\n").lowercased()

                        // Explizit als Attachment markiert
                        if context.contains("content-disposition: attachment") ||
                           context.contains("content-disposition:attachment") {
                            print("📎 [detectAttachments] Found via filename with disposition")
                            return true
                        }

                        // Nicht inline und keine Content-ID (= echtes Attachment)
                        if !context.contains("content-disposition: inline") &&
                           !context.contains("content-disposition:inline") &&
                           !context.contains("content-id:") {
                            print("📎 [detectAttachments] Found via filename (not inline)")
                            return true
                        }
                    }
                }
            }
        }

        // 6. Name parameter im Content-Type (häufig bei Anhängen) - aber nicht für .p7s
        if lowerBody.contains("content-type:") && lowerBody.contains("name=") {
            if !lowerBody.contains("content-id:") ||
               lowerBody.contains("content-disposition: attachment") ||
               lowerBody.contains("content-disposition:attachment") {
                // Prüfe ob es NICHT nur .p7s ist
                if containsRealAttachment(lowerBody) {
                    print("📎 [detectAttachments] Found via name parameter in content-type")
                    return true
                }
            }
        }

        return false
    }

    /// Prüft ob der Body echte Anhänge enthält (nicht nur S/MIME Signaturen)
    private func containsRealAttachment(_ lowerBody: String) -> Bool {
        // Liste von echten Anhang-Indikatoren
        let realAttachmentIndicators = [
            "application/pdf",
            "application/msword",
            "application/vnd.openxmlformats",
            "application/vnd.ms-excel",
            "application/vnd.ms-powerpoint",
            "application/zip",
            "application/octet-stream",
            ".pdf\"", ".doc\"", ".docx\"", ".xls\"", ".xlsx\"",
            ".ppt\"", ".pptx\"", ".zip\"", ".rar\""
        ]

        for indicator in realAttachmentIndicators {
            if lowerBody.contains(indicator) {
                return true
            }
        }
        return false
    }

    /// Extrahiert den Content-Type aus dem rawBody
    private func extractContentType(from rawBody: String) -> String? {
        let lines = rawBody.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("content-type:") {
                let value = trimmed.dropFirst("content-type:".count)
                    .trimmingCharacters(in: .whitespaces)
                // Nur den Teil vor dem Semikolon zurückgeben
                if let semicolonIndex = value.firstIndex(of: ";") {
                    return String(value[..<semicolonIndex]).trimmingCharacters(in: .whitespaces)
                }
                return value
            }
        }
        return nil
    }

    /// Extrahiert den Charset aus dem rawBody
    private func extractCharset(from rawBody: String) -> String? {
        let lowerBody = rawBody.lowercased()
        if let charsetRange = lowerBody.range(of: "charset=") {
            let afterCharset = lowerBody[charsetRange.upperBound...]
            var charset = ""
            for char in afterCharset {
                if char == ";" || char == "\n" || char == "\r" || char == " " || char == "\"" {
                    if !charset.isEmpty { break }
                } else {
                    charset.append(char)
                }
            }
            return charset.isEmpty ? nil : charset
        }
        return nil
    }
}

