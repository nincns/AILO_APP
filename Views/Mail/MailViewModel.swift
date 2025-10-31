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
                emailAddress: cfg.replyTo ?? cfg.recvUsername,
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
        
        do {
            // 🚀 NEU: Verwende spezielle Cache-Methode ohne Netzwerk-Operationen
            let headers = try MailRepository.shared.loadCachedHeaders(
                accountId: accountId,
                folder: folder,
                limit: 100,
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
                limit: 100,
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
        } catch {
            print("❌ refreshMails error: \(error)")
            await MainActor.run {
                self.lastError = error.localizedDescription
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
        
        // 🚀 NEU: Verwende inkrementelle Synchronisation
        print("📈 Triggering incremental sync...")
        MailRepository.shared.incrementalSync(accountId: accountId, folders: nil)
        print("📧 Incremental sync triggered")
        
        // Warte kürzer, da inkrementeller Sync effizienter ist
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 Sekunden
        print("📧 syncAccount finished waiting")
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
}