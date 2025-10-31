// AILO_APP/Configuration/Services/Mail/MailRepository.swift
// Unified interface for UI and features to access mail data.
// Exposes high-level functions: listHeaders(), getBody(), sync(account:), send(message:).
// Internally uses specialized DAOs, MailSyncEngine, MailSendService, and FolderDiscoveryService.
// NOTE: This is the single entry point the UI should depend on.

import Foundation
import Combine
import SwiftUI

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

    // Sync
    public func sync(accountId: UUID, folders: [String]? = nil) {
        print("🔥 MailRepository.sync() called for account: \(accountId)")
        let folderList = folders ?? ["INBOX"]
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
        
        let folderList = folders ?? ["INBOX"]
        
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

