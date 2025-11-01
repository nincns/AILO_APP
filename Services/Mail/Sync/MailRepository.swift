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
                    print("🔄 Full refresh syncing folder: \(folder)")
                    
                    let result = await transport.fetchHeaders(
                        limit: 100, // Larger limit for full refresh
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
                    print("🔧 [MailRepository] preferCache: false, force: true, limit: 50")
                    
                    let result = await transport.fetchHeaders(
                        limit: 50, // Start with latest 50
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
                    print("📈 Checking folder for new messages: \(folder)")
                    
                    // For incremental sync, we prefer cache but force a refresh
                    let result = await transport.fetchHeaders(
                        limit: 20, // Smaller limit for incremental
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
                
                // ✅ RAW-first Storage
                let bodyEntity = MessageBodyEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: uid,
                    text: nil,              // ← Leer lassen (später Processing)
                    html: nil,              // ← Leer lassen (später Processing)
                    hasAttachments: false,  // ← Später aus rawBody erkennen
                    rawBody: rawBody,       // ← NUR RAW speichern
                    contentType: nil,       // ← Später extrahieren
                    charset: nil,           // ← Später extrahieren
                    transferEncoding: nil,
                    isMultipart: false,     // ← Später aus rawBody erkennen
                    rawSize: rawBody.count,
                    processedAt: nil        // ← NIL = nicht verarbeitet
                )
                
                // Store in database
                if let writeDAO = self.writeDAO {
                    try writeDAO.storeBody(accountId: accountId, folder: folder, uid: uid, body: bodyEntity)
                    print("✅ [MailRepository] Stored RAW body for UID: \(uid) - size: \(rawBody.count) bytes")
                }
                
            case .failure(let error):
                print("❌ Failed to fetch body for UID: \(uid): \(error)")
            }
            
        } catch {
            print("❌ Error fetching/storing body for UID: \(uid): \(error)")
        }
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
        
        // ✅ Cast zu BaseDAO für direkten SQL-Zugriff
        guard let baseDAO = dao as? BaseDAO else {
            print("❌ DAO is not a BaseDAO, falling back to slow method")
            // Fallback zur alten Methode
            let headers = try dao.headers(accountId: accountId, folder: folder, limit: 1000, offset: 0)
            var statusMap: [String: Bool] = [:]
            for header in headers {
                do {
                    let attachments = try dao.attachments(accountId: accountId, folder: folder, uid: header.id)
                    statusMap[header.id] = !attachments.isEmpty
                } catch {
                    statusMap[header.id] = false
                }
            }
            return statusMap
        }
        
        print("📎 [OPTIMIZED] Loading attachment status for account: \(accountId), folder: \(folder)")
        
        // ✅ OPTIMIERT: Eine einzige SQL-Query!
        let sql = """
            SELECT uid, has_attachments 
            FROM \(MailSchema.tMsgBody) 
            WHERE account_id = ? AND folder = ?
        """
        
        let stmt = try baseDAO.prepare(sql)
        defer { baseDAO.finalize(stmt) }
        
        baseDAO.bindUUID(stmt, 1, accountId)
        baseDAO.bindText(stmt, 2, folder)
        
        var statusMap: [String: Bool] = [:]
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            // Direkte SQLite-Funktion verwenden statt baseDAO.columnText
            if let cString = sqlite3_column_text(stmt, 0) {
                let uid = String(cString: cString)
                let hasAttachments = sqlite3_column_int(stmt, 1) != 0
                statusMap[uid] = hasAttachments
                
                // Debug ersten 3 Einträge
                if statusMap.count <= 3 {
                    print("📎 [DEBUG] UID: \(uid), hasAttachments: \(hasAttachments)")
                }
            }
        }
        
        print("📎 Loaded attachment status for \(statusMap.count) messages")
        return statusMap
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
}

