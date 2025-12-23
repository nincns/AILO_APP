// MailViewModel.swift - Zentrale View Model für Mail-Management in AILO_APP
import SwiftUI
import Combine
import Foundation

@MainActor final class MailViewModel: ObservableObject {
    @Published var accounts: [AccountEntity] = []
    @Published var filteredMails: [MessageHeaderEntity] = []
    @Published var unreadCount: Int = 0
    @Published var outboxCount: Int = 0
    @Published var draftsCount: Int = 0

    @Published var lastError: String? = nil
    @Published var isLoading: Bool = false

    @Published var availableMailboxes: Set<MailboxType> = [.inbox]

    // MARK: - Phase 2: Folder-State Management
    @Published var allServerFolders: [String] = []          // Alle Ordner vom Server
    @Published var isLoadingFolders: Bool = false           // Loading-State
    @Published var selectedFolder: String? = nil            // Aktuell gewählter Custom-Folder
    @Published var attachmentStatus: [String: Bool] = [:]   // uid -> hasAttachments

    // MARK: - Viewport-Based Sync Manager
    /// Scope-basierte Synchronisation: Nur sichtbare Mails werden synchronisiert
    private(set) lazy var viewportManager: ViewportSyncManager = {
        ViewportSyncManager(repository: MailRepository.shared)
    }()

    private var syncingAccounts: Set<UUID> = []
    private var accountsChangedObserver: AnyCancellable?
    private var activeChangedObserver: AnyCancellable?
    
    init() {
        // 🔧 FIX: Listen for both account list and active status changes
        accountsChangedObserver = NotificationCenter.default
            .publisher(for: .mailAccountsDidChange)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.loadAccounts() }
            }
    }
    
    func loadAccounts() async {
        // Load accounts from the same storage used by MailEditor/MailManager
        let key = "mail.accounts"
        let loaded: [MailAccountConfig] = {
            if let data = UserDefaults.standard.data(forKey: key),
               let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data) {
                return list
            }
            return []
        }()
        
        let activeKey = "mail.accounts.active"
        let activeIDs: Set<UUID> = {
            if let data = UserDefaults.standard.data(forKey: activeKey),
               let arr = try? JSONDecoder().decode([UUID].self, from: data) {
                return Set(arr)
            }
            return []
        }()
        
        // 🔧 Debug: Log account filtering for troubleshooting
        print("🔍 MailView Debug - Total configured accounts: \(loaded.count)")
        print("🔍 MailView Debug - Active account IDs: \(activeIDs.count)")
        loaded.forEach { cfg in
            let isActive = activeIDs.contains(cfg.id)
            print("🔍 Account: \(cfg.accountName) (\(cfg.id)) - Active: \(isActive)")
        }
        
        let filtered = loaded.filter { activeIDs.contains($0.id) }
        print("🔍 MailView Debug - Filtered active accounts: \(filtered.count)")
        
        let mapped: [AccountEntity] = filtered.map { cfg in
            AccountEntity(
                id: cfg.id,
                displayName: cfg.displayName ?? cfg.accountName,
                emailAddress: cfg.emailAddress,
                hostIMAP: cfg.recvHost,
                hostSMTP: cfg.smtpHost,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
        await MainActor.run { 
            self.accounts = mapped
            print("🔍 MailView Debug - Final mapped accounts: \(mapped.count)")
        }

        // Single observer to handle both account list and active changes
        accountsChangedObserver = NotificationCenter.default
            .publisher(for: .mailAccountsDidChange)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { 
                    // 🔧 FIX: Reload mailManager accounts when accounts change
                    await self.reloadAccountsAndMailboxes() 
                }
            }
    }
    
    private func reloadAccountsAndMailboxes() async {
        // 🔧 FIX: Update accounts and reload mailboxes
        await loadAccounts()
        
        if let firstAccountId = accounts.first?.id {
            await loadAvailableMailboxes(for: firstAccountId)
        } else {
            await MainActor.run { self.availableMailboxes = [.inbox] }
        }
    }
    
    func loadAvailableMailboxes(for accountId: UUID?) async {
        print("🔍 loadAvailableMailboxes called for accountId: \(accountId?.uuidString ?? "nil")")
        guard let accountId = accountId else {
            await MainActor.run { self.availableMailboxes = [.inbox] }
            return
        }

        let key = "mail.accounts"
        let loaded: [MailAccountConfig] = {
            if let data = UserDefaults.standard.data(forKey: key),
               let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data) {
                return list
            }
            return []
        }()

        guard let account = loaded.first(where: { $0.id == accountId }) else {
            print("❌ Account nicht gefunden: \(accountId)")
            await MainActor.run { self.availableMailboxes = [.inbox] }
            return
        }

        print("📁 Folders: inbox=\(account.folders.inbox), sent=\(account.folders.sent), drafts=\(account.folders.drafts), trash=\(account.folders.trash), spam=\(account.folders.spam)")

        var set: Set<MailboxType> = []
        set.insert(.inbox)
        if !account.folders.sent.isEmpty { set.insert(.sent) }
        if !account.folders.drafts.isEmpty { set.insert(.drafts) }
        if !account.folders.trash.isEmpty { set.insert(.trash) }
        if !account.folders.spam.isEmpty { set.insert(.spam) }

        print("✅ Verfügbare Mailboxen: \(set)")
        await MainActor.run { self.availableMailboxes = set }
        
        // PHASE 2: Zusätzlich alle Server-Ordner laden
        await loadAllServerFolders(accountId: accountId)
        
        // Task für Server-Folder-Discovery im Hintergrund
        Task {
            await loadAllServerFolders(accountId: accountId)
        }
    }
    
    // MARK: - Phase 2: Folder Management
    
    /// 2.1 Lädt alle Ordner vom Server
    func loadAllServerFolders(accountId: UUID) async {
        print("📁 loadAllServerFolders called for accountId: \(accountId)")
        
        // Loading-State aktivieren
        await MainActor.run { 
            self.isLoadingFolders = true
            self.lastError = nil
        }
        
        do {
            // Account-Konfiguration laden für Filter-Logik
            guard let account = accountConfig(for: accountId) else {
                await MainActor.run {
                    self.lastError = "Account configuration not found"
                    self.allServerFolders = []
                    self.isLoadingFolders = false
                }
                return
            }
            
            // Alle Server-Ordner via MailRepository laden
            let result = await MailRepository.shared.getAllServerFolders(accountId: accountId)
            
            switch result {
            case .success(let folders):
                print("✅ Loaded \(folders.count) server folders: \(folders)")
                
                // Filter anwenden: Nur Custom-Ordner (keine SpecialFolders)
                let customFolders = filterCustomFolders(folders, account: account)
                
                await MainActor.run {
                    self.allServerFolders = customFolders  // Bereits in filterCustomFolders sortiert
                    self.isLoadingFolders = false
                }
                
            case .failure(let error):
                print("❌ Failed to load server folders: \(error)")
                
                await MainActor.run {
                    self.lastError = "Failed to load folders: \(error.localizedDescription)"
                    self.allServerFolders = []  // Bei Fehler: leere Liste
                    self.isLoadingFolders = false
                }
            }
            
        } catch {
            print("❌ Unexpected error in loadAllServerFolders: \(error)")
            
            await MainActor.run {
                self.lastError = "Unexpected error: \(error.localizedDescription)"
                self.allServerFolders = []
                self.isLoadingFolders = false
            }
        }
    }
    
    /// 2.2 Lädt Mails für beliebigen Ordner
    func loadMailsForFolder(folder: String, accountId: UUID) async {
        print("📂 loadMailsForFolder called - folder: '\(folder)', accountId: \(accountId)")

        // 📍 ViewportSyncManager: Setze Kontext für scope-basierte Sync
        viewportManager.setContext(accountId: accountId, folder: folder)

        // Loading-State aktivieren
        await MainActor.run {
            self.isLoading = true
            self.lastError = nil
        }
        
        do {
            // 1. Zuerst Cache laden (sofortige UI-Anzeige)
            print("📱 Loading cached headers for custom folder: \(folder)")
            let cachedHeaders = try MailRepository.shared.loadCachedHeaders(
                accountId: accountId,
                folder: folder,
                limit: 5000,
                offset: 0
            )
            
            // Cache-Daten sofort in UI anzeigen
            let cachedEntities: [MessageHeaderEntity] = cachedHeaders.map { header in
                MessageHeaderEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: header.id,
                    from: header.from,
                    subject: header.subject,
                    date: header.date,
                    flags: header.flags
                )
            }
            
            await MainActor.run {
                // Sowohl Cache ALS AUCH filteredMails aktualisieren für konsistenten Zugriff
                self.customFolderCache[folder] = cachedEntities  // Cache aktualisieren
                self.filteredMails = cachedEntities              // Auch filteredMails setzen
                self.selectedFolder = folder  // Aktuell gewählten Folder setzen
                print("📱 Loaded \(cachedEntities.count) cached messages for folder: \(folder)")
            }
            
            // 2. Dann aktualisierte Daten vom Server laden (Hintergrund-Sync)
            print("🔄 Triggering sync for custom folder: \(folder)")
            MailRepository.shared.incrementalSync(accountId: accountId, folders: [folder])
            
            // Kurz warten auf Sync-Ergebnis
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 Sekunde
            
            // 3. Aktualisierte Daten aus DAO laden
            print("📂 Loading fresh headers after sync for folder: \(folder)")
            let freshHeaders = try MailRepository.shared.listHeaders(
                accountId: accountId,
                folder: folder,
                limit: 5000,
                offset: 0
            )
            
            let freshEntities: [MessageHeaderEntity] = freshHeaders.map { header in
                MessageHeaderEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: header.id,
                    from: header.from,
                    subject: header.subject,
                    date: header.date,
                    flags: header.flags
                )
            }
            
            await MainActor.run {
                // Sowohl Cache ALS AUCH filteredMails aktualisieren für konsistenten Zugriff
                self.customFolderCache[folder] = freshEntities   // Cache aktualisieren
                self.filteredMails = freshEntities               // Auch filteredMails setzen
                self.isLoading = false
                print("✅ Final result: \(freshEntities.count) messages in folder: \(folder)")
                
                // Badge-Counts für diesen Account aktualisieren
                self.updateBadgeCounts(accountId: accountId)
            }
            
            // Attachment-Status für Custom-Folder laden
            Task {
                await self.loadAttachmentStatus(accountId: accountId, folder: folder)
            }
            
        } catch {
            print("❌ loadMailsForFolder error: \(error)")
            
            await MainActor.run {
                self.lastError = "Failed to load folder '\(folder)': \(error.localizedDescription)"
                self.isLoading = false
                // filteredMails nicht leeren - behalte Cache-Daten falls vorhanden
            }
        }
    }
    
    /// 2.3 Filter: Nur Custom-Ordner (keine SpecialFolders)
    private func filterCustomFolders(_ allFolders: [String], account: MailAccountConfig) -> [String] {
        print("🔍 filterCustomFolders called with \(allFolders.count) folders")
        
        // Set für schnelles Lookup
        var excludedFolders = Set<String>()
        
        // 1. WICHTIG: Konfigurierte Special-Folders aus Account ausschließen
        //    Diese sind bereits vom Server abgerufen und gespeichert!
        let configuredSpecialFolders = [
            account.folders.inbox,
            account.folders.sent,
            account.folders.drafts, 
            account.folders.trash,
            account.folders.spam
        ]
        
        for folder in configuredSpecialFolders {
            if !folder.isEmpty {
                excludedFolders.insert(folder)
                print("🔍 Excluding configured special folder: '\(folder)'")
            }
        }
        
        // 2. OPTIONAL: Häufige Varianten ausschließen (Fallback für alte Accounts)
        //    Nur als Sicherheitsnetz für Accounts die noch keine Discovery hatten
        let commonVariants = [
            // Englisch - ALLE Case-Varianten
            "INBOX", "Inbox", "inbox",
            "Sent", "sent", "Sent Items", "Sent Messages", "Sent Mail",
            "Drafts", "drafts", "Draft", "draft",
            "Trash", "trash", "Deleted Items", "Deleted Messages", "Deleted", "deleted",
            "Spam", "spam", "SPAM",
            "Junk", "junk", "JUNK", "Junk E-mail", "Junk Email", "Junk Mail",
            
            // Deutsch
            "Gesendet", "gesendet", "Gesendete Elemente", "Gesendete Objekte",
            "Entwürfe", "entwürfe", "Entwurf", "entwurf",
            "Papierkorb", "papierkorb", "Gelöscht", "gelöscht", "Gelöschte Elemente",
            "Unerwünscht", "unerwünscht",
            
            // Französisch
            "Envoyés", "envoyés", "Éléments envoyés",
            "Brouillons", "brouillons",
            "Corbeille", "corbeille", "Éléments supprimés",
            "Courrier indésirable",
            
            // Spanisch
            "Enviados", "enviados", "Elementos enviados",
            "Borradores", "borradores",
            "Papelera", "papelera", "Elementos eliminados",
            "Correo no deseado"
        ]
        
        for variant in commonVariants {
            excludedFolders.insert(variant)
        }
        
        // 3. Gmail-spezifische Ordner ausschließen
        let gmailFolders = [
            "[Gmail]",
            "[Gmail]/All Mail",
            "[Gmail]/Starred",
            "[Gmail]/Important"
        ]
        
        for folder in gmailFolders {
            excludedFolders.insert(folder)
        }
        
        // 4. ⭐️ CASE-INSENSITIVE Filtern!
        // Erstelle lowercase Set für case-insensitive Vergleich
        let excludedLowercase = Set(excludedFolders.map { $0.lowercased() })
        
        let customFolders = allFolders.filter { folder in
            let folderLower = folder.lowercased()
            let isExcluded = excludedLowercase.contains(folderLower)
            
            if isExcluded {
                print("🔍 Filtering out: '\(folder)' (matched '\(folderLower)')")
            }
            
            return !isExcluded
        }
        
        print("🔍 Filtered to \(customFolders.count) custom folders: \(customFolders)")
        print("🔍 Excluded \(excludedFolders.count) special folders")
        
        return customFolders.sorted()
    }
    
    /// Lädt Attachment-Status für effiziente UI-Anzeige
    private func loadAttachmentStatus(accountId: UUID, folder: String) async {
        print("🔍 [DEBUG] Starting attachment status loading...")
        print("🔍 [DEBUG] AccountId: \(accountId)")
        print("🔍 [DEBUG] Folder: \(folder)")
        
        do {
            // ✅ FIX: MainActor-kompatible Ausführung
            let statusMap = await MainActor.run {
                do {
                    return try MailRepository.shared.loadAttachmentStatus(accountId: accountId, folder: folder)
                } catch {
                    print("❌ [DEBUG] Failed to load attachment status: \(error)")
                    return [String: Bool]()
                }
            }
            
            print("📎 [DEBUG] Total status map: \(statusMap.count) entries")

            // Log wie viele tatsächlich Attachments haben
            let withAttachments = statusMap.filter { $0.value }.count
            print("📎 [DEBUG] Messages with attachments: \(withAttachments)/\(statusMap.count)")

            await MainActor.run {
                self.attachmentStatus = statusMap
                print("📎 Loaded attachment status for \(statusMap.count) messages")
            }
        } catch {
            print("❌ [DEBUG] Outer catch - Failed to load attachment status: \(error)")
            await MainActor.run {
                self.attachmentStatus = [:]
            }
        }
    }
    
    /// 🚀 NEU: Lädt Mails sofort aus lokalem Cache ohne Sync-Wartezeit
    func loadCachedMails(for mailbox: MailboxType, accountId: UUID?) async {
        let accIdStr = accountId?.uuidString ?? "nil"
        print("📱 loadCachedMails called for mailbox: \(mailbox), accountId: \(accIdStr)")

        guard let accountId = accountId else {
            print("❌ No accountId provided for cached loading")
            return
        }

        let folder = await folderNameForMailbox(mailbox, accountId: accountId)
        print("📂 Loading cached data from folder: \(folder)")

        // 📍 ViewportSyncManager: Setze Kontext für scope-basierte Sync
        viewportManager.setContext(accountId: accountId, folder: folder)
        
        do {
            // 🚀 NEU: Verwende spezielle Cache-Methode ohne Netzwerk-Operationen
            let headers = try MailRepository.shared.loadCachedHeaders(
                accountId: accountId,
                folder: folder,
                limit: 5000,
                offset: 0
            )
            
            let entities: [MessageHeaderEntity] = headers.map { h in
                MessageHeaderEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: h.id,
                    from: h.from,
                    subject: h.subject,
                    date: h.date,
                    flags: h.flags
                )
            }
            
            await MainActor.run {
                self.filteredMails = entities
                print("📱 Cached mails loaded instantly: \(entities.count) messages")
                self.updateBadgeCounts(accountId: accountId)
            }
            
            // Attachment-Status parallel laden
            Task {
                await loadAttachmentStatus(accountId: accountId, folder: folder)
            }
            
        } catch {
            print("⚠️ loadCachedMails error: \(error)")
            // Bei Cache-Fehler: leere Liste anzeigen, Sync wird im Hintergrund nachholen
            await MainActor.run {
                self.filteredMails = []
            }
        }
    }
    
    func refreshMails(for mailbox: MailboxType, accountId: UUID?) async {
        let accIdStr = accountId?.uuidString ?? "nil"
        print("📬 refreshMails called for mailbox: \(mailbox), accountId: \(accIdStr)")
        await MainActor.run { self.isLoading = true; self.lastError = nil }
        guard let accountId = accountId else {
            print("❌ No accountId provided")
            await MainActor.run { self.isLoading = false }
            return
        }
        let folder = await folderNameForMailbox(mailbox, accountId: accountId)
        print("📂 Loading from folder: \(folder)")
        do {
            // Fetch from DAO (which was populated by MailSyncEngine)
            let headers = try MailRepository.shared.listHeaders(
                accountId: accountId,
                folder: folder,
                limit: 5000,
                offset: 0
            )
            print("✅ Loaded \(headers.count) headers from DB")
            // Convert MailDAO.Header to MessageHeaderEntity
            let entities = headers.map { h in
                MessageHeaderEntity(
                    accountId: accountId,
                    folder: folder,
                    uid: h.id,
                    from: h.from,
                    subject: h.subject,
                    date: h.date,
                    flags: h.flags
                )
            }
            await MainActor.run {
                self.filteredMails = entities
                print("📋 Updated filteredMails: \(entities.count) messages")
                self.updateBadgeCounts(accountId: accountId)
                self.isLoading = false
            }
            
            // Attachment-Status parallel laden
            Task {
                await loadAttachmentStatus(accountId: accountId, folder: folder)
            }
        } catch {
            print("❌ refreshMails error: \(error)")
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    /// PHASE 2.3: Überladene refreshMails für Custom-Folders
    func refreshMails(for folderName: String, accountId: UUID?) async {
        let accIdStr = accountId?.uuidString ?? "nil"
        print("📬 refreshMails called for custom folder: '\(folderName)', accountId: \(accIdStr)")
        
        await MainActor.run { 
            self.isLoading = true
            self.lastError = nil
        }
        
        guard let accountId = accountId else {
            print("❌ No accountId provided")
            await MainActor.run { self.isLoading = false }
            return
        }
        
        print("📂 Loading from custom folder: \(folderName)")
        
        do {
            // Fetch from DAO (which was populated by MailSyncEngine)
            let headers = try MailRepository.shared.listHeaders(
                accountId: accountId,
                folder: folderName,
                limit: 5000,
                offset: 0
            )

            print("✅ Loaded \(headers.count) headers from DB for custom folder: \(folderName)")
            
            // Convert MailDAO.Header to MessageHeaderEntity
            let entities = headers.map { h in
                MessageHeaderEntity(
                    accountId: accountId,
                    folder: folderName,
                    uid: h.id,
                    from: h.from,
                    subject: h.subject,
                    date: h.date,
                    flags: h.flags
                )
            }
            
            await MainActor.run {
                self.filteredMails = entities
                self.selectedFolder = folderName  // Custom Folder als aktuell gewählt markieren
                print("📋 Updated filteredMails: \(entities.count) messages from custom folder: \(folderName)")
                self.updateBadgeCounts(accountId: accountId)
                self.isLoading = false
            }
            
            // Attachment-Status für Custom-Folder laden
            Task {
                await self.loadAttachmentStatus(accountId: accountId, folder: folderName)
            }
            
        } catch {
            print("❌ refreshMails error for custom folder '\(folderName)': \(error)")
            await MainActor.run {
                self.lastError = "Failed to refresh folder '\(folderName)': \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func folderNameForMailbox(_ mailbox: MailboxType, accountId: UUID) async -> String {
        // Load account config to get folder mappings
        let key = "mail.accounts"
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let acc = list.first(where: { $0.id == accountId }) else {
            return "INBOX" // Fallback
        }
        switch mailbox {
        case .inbox:  return acc.folders.inbox
        case .sent:   return acc.folders.sent
        case .drafts: return acc.folders.drafts
        case .trash:  return acc.folders.trash
        case .spam:   return acc.folders.spam
        case .outbox: return "" // Outbox is local-only
        }
    }

    private func updateBadgeCounts(accountId: UUID) {
        do {
            // Count unread in INBOX via repository (DAO-backed)
            let inboxHeaders = try MailRepository.shared.listHeaders(accountId: accountId, folder: "INBOX", limit: 1000, offset: 0)
            self.unreadCount = inboxHeaders.filter { !$0.flags.contains("\\Seen") }.count
            // Outbox count from MailSendService
            let outbox = try MailSendService.shared.dao?.loadAll(accountId: accountId) ?? []
            self.outboxCount = outbox.filter { $0.status == .pending || $0.status == .sending }.count
            self.draftsCount = 0 // TODO: Count drafts folder
        } catch {
            MailLogger.shared.error(.LIST, accountId: accountId, "updateBadgeCounts error: \(error)")
        }
    }
    
    func syncAccount(_ accountId: UUID) async {
        print("📧 syncAccount called for: \(accountId)")
        syncingAccounts.insert(accountId)
        defer { syncingAccounts.remove(accountId) }
        
        // PHASE 4: Alle konfigurierten Ordner synchronisieren
        let allFolders = MailRepository.shared.getAllConfiguredFolders(accountId: accountId)
        print("📁 Syncing account with all configured folders: \(allFolders)")
        
        // 🚀 NEU: Verwende inkrementelle Synchronisation für alle Ordner
        print("📈 Triggering incremental sync for \(allFolders.count) folders...")
        MailRepository.shared.incrementalSync(accountId: accountId, folders: allFolders)
        print("📧 Incremental sync triggered for all folders")
        
        // Warte kürzer, da inkrementeller Sync effizienter ist
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 Sekunden
        print("📧 syncAccount finished waiting - synced \(allFolders.count) folders")
    }
    
    func isAccountSyncing(_ accountId: UUID) -> Bool {
        syncingAccounts.contains(accountId)
    }
    
    func deleteMail(_ mail: MessageHeaderEntity) async {
        await withIMAP(accountId: mail.accountId, folder: mail.folder, readOnly: false) { _, conn in
            // Mark \Deleted via UID STORE and attempt UID EXPUNGE; fallback to EXPUNGE
            let client = IMAPClient(connection: conn)
            try await client.store(uids: [mail.uid], flags: ["\\Deleted"], mode: .add)
            // Try UID EXPUNGE for this UID; if unsupported, fall back to EXPUNGE
            try await self.sendTagged(conn: conn, command: "UID EXPUNGE \(mail.uid)")
        }
        // If UID EXPUNGE failed and threw, we attempt a generic EXPUNGE in the helper; UI should still update.
        // Update local list optimistically
        self.filteredMails.removeAll { $0.accountId == mail.accountId && $0.folder == mail.folder && $0.uid == mail.uid }
        self.updateBadgeCounts(accountId: mail.accountId)
    }
    
    func toggleFlag(_ mail: MessageHeaderEntity, flag: String) async {
        let has = mail.flags.contains(flag)
        await withIMAP(accountId: mail.accountId, folder: mail.folder, readOnly: false) { _, conn in
            let client = IMAPClient(connection: conn)
            try await client.store(uids: [mail.uid], flags: [flag], mode: has ? .remove : .add)
        }
        // Update in-memory flags for immediate UI feedback
        applyFlagLocally(uids: [mail.uid], folder: mail.folder, flag: flag, add: !has)
        self.updateBadgeCounts(accountId: mail.accountId)
    }
    
    func toggleReadStatus(_ mail: MessageHeaderEntity) async {
        let flag = "\\Seen"
        let isRead = mail.flags.contains(flag)
        await withIMAP(accountId: mail.accountId, folder: mail.folder, readOnly: false) { _, conn in
            let client = IMAPClient(connection: conn)
            try await client.store(uids: [mail.uid], flags: [flag], mode: isRead ? .remove : .add)
        }
        applyFlagLocally(uids: [mail.uid], folder: mail.folder, flag: flag, add: !isRead)
        self.updateBadgeCounts(accountId: mail.accountId)
    }
    
    func markAllRead(in mails: [MessageHeaderEntity]) async {
        await batchToggleSeen(in: mails, add: true)
    }

    func markAllUnread(in mails: [MessageHeaderEntity]) async {
        await batchToggleSeen(in: mails, add: false)
    }
    
    // MARK: - IMAP helpers

    private func withIMAP(accountId: UUID, folder: String, readOnly: Bool, _ work: @escaping (IMAPCommands, IMAPConnection) async throws -> Void) async {
        guard let acc = accountConfig(for: accountId) else { await MainActor.run { self.lastError = "Account not found" }; return }
        let conn = IMAPConnection(label: "ui.vm.\(accountId.uuidString.prefix(6))")
        do {
            let useTLS = (acc.recvEncryption == .sslTLS)
            let cfg = IMAPConnectionConfig(
                host: acc.recvHost,
                port: acc.recvPort,
                tls: useTLS,
                sniHost: acc.recvHost,
                connectionTimeoutSec: acc.connectionTimeoutSec,
                commandTimeoutSec: max(5, acc.connectionTimeoutSec/2),
                idleTimeoutSec: 10
            )
            try await conn.open(cfg)
            let cmds = IMAPCommands()
            _ = try await cmds.greeting(conn)
            if acc.recvEncryption == .startTLS { try await cmds.startTLS(conn) }
            guard let pwd = acc.recvPassword else { throw IMAPError.invalidState("No password") }
            try await cmds.login(conn, user: acc.recvUsername, pass: pwd)
            _ = try await cmds.select(conn, folder: folder, readOnly: readOnly)
            try await work(cmds, conn)
            try? await cmds.logout(conn)
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
        }
        conn.close()
    }

    private func sendTagged(conn: IMAPConnection, command: String, idle: TimeInterval = 8.0) async throws {
        let tag = "C\(Int.random(in: 1000...9999))"
        try await conn.send(line: "\(tag) \(command)")
        let lines = try await conn.receiveLines(untilTag: tag, idleTimeout: idle)
        // If UID EXPUNGE is not supported, server may reply NO/BAD; try plain EXPUNGE then.
        if let last = lines.last, !(last.hasPrefix("\(tag) OK")) {
            // Fallback to generic EXPUNGE
            let tag2 = "C\(Int.random(in: 1000...9999))"
            try await conn.send(line: "\(tag2) EXPUNGE")
            _ = try await conn.receiveLines(untilTag: tag2, idleTimeout: idle)
        }
    }

    private func accountConfig(for accountId: UUID) -> MailAccountConfig? {
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else { return nil }
        return list.first(where: { $0.id == accountId })
    }

    private func applyFlagLocally(uids: [String], folder: String, flag: String, add: Bool) {
        let set = Set(uids)
        
        // Update filteredMails (for currently displayed mails)
        self.filteredMails = self.filteredMails.map { m in
            guard m.folder == folder, set.contains(m.uid) else { return m }
            var copy = m
            if add {
                if !copy.flags.contains(flag) { copy.flags.append(flag) }
            } else {
                copy.flags.removeAll { $0 == flag }
            }
            return copy
        }
        
        // PHASE 6: Update customFolderCache (for cached custom folder mails)
        if var cachedMails = customFolderCache[folder] {
            customFolderCache[folder] = cachedMails.map { m in
                guard set.contains(m.uid) else { return m }
                var copy = m
                if add {
                    if !copy.flags.contains(flag) { copy.flags.append(flag) }
                } else {
                    copy.flags.removeAll { $0 == flag }
                }
                return copy
            }
        }
    }

    private func batchToggleSeen(in mails: [MessageHeaderEntity], add: Bool) async {
        struct FolderKey: Hashable { let accountId: UUID; let folder: String }
        let groups = Dictionary(grouping: mails, by: { FolderKey(accountId: $0.accountId, folder: $0.folder) })
        for (key, items) in groups {
            let accId = key.accountId
            let folder = key.folder
            let uids = Array(Set(items.map { $0.uid }))
            await self.withIMAP(accountId: accId, folder: folder, readOnly: false) { [add, uids] _, conn in
                let client = IMAPClient(connection: conn)
                try await client.store(uids: uids, flags: ["\\Seen"], mode: add ? .add : .remove)
            }
            self.applyFlagLocally(uids: uids, folder: folder, flag: "\\Seen", add: add)
            self.updateBadgeCounts(accountId: accId)
        }
    }
    
    // MARK: - Phase 6: Custom Folder Support
    
    /// Cache für Custom-Folder Mails
    private var customFolderCache: [String: [MessageHeaderEntity]] = [:]
    
    /// Gibt die Mails für einen Custom-Folder zurück
    func customFolderMails(folder: String) -> [MessageHeaderEntity] {
        return customFolderCache[folder] ?? []
    }
    
    /// Prüft, ob ein Custom-Folder bereits Mails im Cache hat
    func hasCustomFolderMails(folder: String) -> Bool {
        return !customFolderCache[folder, default: []].isEmpty
    }
    
    /// Gibt die Anzahl der Mails in einem Custom-Folder zurück
    func customFolderMailCount(folder: String) -> Int {
        return customFolderCache[folder, default: []].count
    }
    
    /// Gibt die Anzahl der ungelesenen Mails in einem Custom-Folder zurück
    func customFolderUnreadCount(folder: String) -> Int {
        return customFolderCache[folder, default: []]
            .filter { !$0.flags.contains("\\Seen") }
            .count
    }
    
    /// Löscht den Cache für einen spezifischen Custom-Folder
    func clearCustomFolderCache(folder: String) {
        customFolderCache.removeValue(forKey: folder)
    }
    
    /// Löscht den gesamten Custom-Folder Cache
    func clearAllCustomFolderCaches() {
        customFolderCache.removeAll()
    }
    
    /// Aktualisiert einen einzelnen Mail-Header in allen relevanten Caches
    private func updateHeaderInCaches(updatedHeader: MessageHeaderEntity) {
        // Update in filteredMails wenn es der aktuelle Folder ist
        if let index = filteredMails.firstIndex(where: { $0.uid == updatedHeader.uid && $0.folder == updatedHeader.folder }) {
            filteredMails[index] = updatedHeader
        }
        
        // Update in customFolderCache
        if var cachedMails = customFolderCache[updatedHeader.folder] {
            if let index = cachedMails.firstIndex(where: { $0.uid == updatedHeader.uid }) {
                cachedMails[index] = updatedHeader
                customFolderCache[updatedHeader.folder] = cachedMails
            }
        }
    }
    
    /// Entfernt gelöschte Nachrichten aus allen Caches
    private func removeFromCaches(uids: [String], folder: String) {
        let uidSet = Set(uids)
        
        // Remove from filteredMails
        self.filteredMails.removeAll { m in
            m.folder == folder && uidSet.contains(m.uid)
        }
        
        // Remove from customFolderCache
        if var cachedMails = customFolderCache[folder] {
            cachedMails.removeAll { m in
                uidSet.contains(m.uid)
            }
            customFolderCache[folder] = cachedMails
        }
    }
}