// MailView.swift - Zentrale Mail-Übersicht für AILO_APP
import SwiftUI
import Combine

struct MailView: View {
    @EnvironmentObject private var store: DataStore
    @StateObject private var mailManager = MailViewModel()
    
    @State private var selectedMailbox: MailboxType = .inbox
    @State private var selectedAccountId: UUID?
    @State private var searchText: String = ""
    @State private var activeSheet: MailViewActiveSheet?
    @State private var selectedMailUID: String?
    @State private var isRefreshing: Bool = false
    @State private var isBackgroundSyncing: Bool = false  // 🆕 Separater Status für Hintergrund-Sync
    @State private var isMailboxPanelOpen: Bool = false
    @State private var sortMode: MailSortMode = .dateDesc
    @State private var railVerticalOffset: CGFloat = UserDefaults.standard.double(forKey: "mailview.rail.offset")
    
    @State private var quickFilter: QuickFilter = .all
    
    @Environment(\.horizontalSizeClass) private var hSizeClass


    
    private var displayedMails: [MessageHeaderEntity] {
        var list = mailManager.filteredMails
        // Apply quick filter first
        switch quickFilter {
        case .all:
            break
        case .unread:
            list = list.filter { $0.flags.contains("\\Seen") == false }
        case .flagged:
            list = list.filter { $0.flags.contains("\\Flagged") }
        }
        // Lightweight local search on subject/from (visual only)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter { header in
                header.subject.localizedCaseInsensitiveContains(q) || header.from.localizedCaseInsensitiveContains(q)
            }
        }
        // Apply sorting
        switch sortMode {
        case .dateDesc:
            list = list.sorted { a, b in
                switch (a.date, b.date) {
                case let (da?, db?):
                    return da > db
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    return a.subject.localizedCaseInsensitiveCompare(b.subject) == .orderedAscending
                }
            }
        case .sender:
            list = list.sorted { a, b in
                a.from.localizedCaseInsensitiveCompare(b.from) == .orderedAscending
            }
        }
        return list
    }

    private var availableBoxesSorted: [MailboxType] {
        let order: [MailboxType] = [.inbox, .sent, .drafts, .trash, .spam, .outbox]
        return mailManager.availableMailboxes.sorted { a, b in
            (order.firstIndex(of: a) ?? Int.max) < (order.firstIndex(of: b) ?? Int.max)
        }
    }



    var body: some View {
        ZStack(alignment: .leading) {
            // Main content area wrapped in NavigationStack to keep titles and toolbars
            NavigationStack {
                detail
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 8) {
                            Text(mailboxTitle(for: selectedMailbox))
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                            Picker("Filter", selection: $quickFilter) {
                                Text("app.mail.filter.all").tag(QuickFilter.all)
                                Text("app.mail.filter.unread").tag(QuickFilter.unread)
                                Text("app.mail.filter.flagged").tag(QuickFilter.flagged)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            Divider()
                        }
                        .background(.ultraThinMaterial)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                ForEach(mailManager.accounts, id: \.id) { acc in
                                    Button(action: {
                                        self.selectedAccountId = acc.id
                                        Task {
                                            await self.mailManager.loadAvailableMailboxes(for: self.selectedAccountId)
                                            // 🚀 Sofortiges Laden aus Cache bei Account-Wechsel
                                            await self.mailManager.loadCachedMails(for: self.selectedMailbox, accountId: acc.id)
                                            // Hintergrund-Sync für neuen Account
                                            await self.performBackgroundSync(accountId: acc.id)
                                            await self.mailManager.refreshMails(for: self.selectedMailbox, accountId: acc.id)
                                        }
                                    }) {
                                        HStack {
                                            Text(acc.displayName)
                                            if acc.id == selectedAccountId { Image(systemName: "checkmark") }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.crop.circle")
                                    Text(self.mailManager.accounts.first(where: { $0.id == self.selectedAccountId })?.displayName ?? String(localized: "app.mail.accounts"))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { self.activeSheet = .compose }) {
                                Image(systemName: "square.and.pencil")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: { Task { await self.refreshMails() } }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    if isBackgroundSyncing {
                                        Image(systemName: "circle.fill")
                                            .foregroundStyle(.orange)
                                            .font(.caption2)
                                    }
                                }
                            }
                            .disabled(self.isRefreshing)
                        }
                    }
                .toolbar(isMailboxPanelOpen ? .hidden : .visible, for: .navigationBar)
            }

            // Dimming overlay when panel is open; tap to close
            if isMailboxPanelOpen {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut) { self.isMailboxPanelOpen = false } }
            }

            // Left rail and sliding mailbox panel
            mailboxRailAndPanel
        }
        .sheet(item: $activeSheet) { sheet in
            createMailViewSheetContent(
                for: sheet,
                quickFilter: $quickFilter,
                sortMode: $sortMode,
                activeSheet: $activeSheet,
                onMarkAllRead: { await self.markAllRead() },
                onMarkAllUnread: { await self.markAllUnread() },
                onDeleteMail: { mail in await self.deleteMail(mail) },
                onToggleFlag: { mail, flag in await self.toggleFlag(mail, flag: flag) },
                onSyncAccount: { accountId in await self.syncAccount(accountId) },
                onRefreshMails: { await self.refreshMails() }
            )
        }
        .onAppear {
            Task {
                await self.mailManager.loadAccounts()
                if self.selectedAccountId == nil {
                    self.selectedAccountId = self.mailManager.accounts.first?.id
                }
                await self.mailManager.loadAvailableMailboxes(for: self.selectedAccountId)
                
                // 🚀 SOFORT: Cached Mails laden (keine Wartezeit)
                print("📱 Loading cached mails on app start...")
                await self.mailManager.loadCachedMails(for: self.selectedMailbox, accountId: self.selectedAccountId)
                
                // 🔄 ZUSÄTZLICH: Falls noch keine Mails im Cache, starte explizite Sync
                if self.mailManager.filteredMails.isEmpty {
                    print("📧 No cached mails found, triggering immediate sync...")
                    await self.refreshMails()
                }
                
                // 🔄 HINTERGRUND: Inkrementelle Sync parallel starten (für Updates)
                if let accountId = self.selectedAccountId {
                    print("🔄 Starting background incremental sync on app start...")
                    self.isBackgroundSyncing = true
                    
                    Task { @MainActor [accountId] in
                        
                        // Hintergrund-Sync
                        await performBackgroundSync(accountId: accountId)
                        
                        // Nach Sync: UI mit neuen Daten aktualisieren
                        await mailManager.refreshMails(for: selectedMailbox, accountId: accountId)
                        
                        isBackgroundSyncing = false
                    }
                }
            }
        }
        .onChange(of: mailManager.availableMailboxes) { _, newValue in
            if !newValue.contains(self.selectedMailbox) {
                self.selectedMailbox = .inbox
            }
        }
        .onChange(of: selectedAccountId) { oldId, newId in
            guard let newId = newId, oldId != newId else { return }
            Task {
                await self.mailManager.loadAvailableMailboxes(for: newId)
                await MainActor.run {
                    if !self.mailManager.availableMailboxes.contains(self.selectedMailbox) {
                        self.selectedMailbox = .inbox
                    }
                    self.isMailboxPanelOpen = false
                }
                // 🚀 Sofortiges Laden aus Cache bei Account-Wechsel
                await self.mailManager.loadCachedMails(for: self.selectedMailbox, accountId: newId)
                // Background-Sync für neuen Account
                await self.performBackgroundSync(accountId: newId)
                await self.mailManager.refreshMails(for: self.selectedMailbox, accountId: newId)
            }
        }
        .onChange(of: selectedMailbox) { _, newMailbox in
            Task {
                // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel
                await self.mailManager.loadCachedMails(for: newMailbox, accountId: self.selectedAccountId)
            }
        }
    }
    
    @ViewBuilder
    private var mailboxRailAndPanel: some View {
        GeometryReader { geo in
            let validWidth = max(1, geo.size.width)   // ← ensure never 0 or negative
            let validHeight = max(1, geo.size.height) // ← ensure never 0 or negative
            let panelWidth = max(280, validWidth * 0.6)
            let panelHeight = validHeight + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            let railWidth: CGFloat = 56

            // Left icon rail (compact; draggable vertically)
            VStack {
                Spacer(minLength: 0)

                // Inner rail box
                VStack(spacing: 0) {
                    // Expand button (draggable)
                    Button {
                        withAnimation(.easeInOut) { self.isMailboxPanelOpen = true }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .imageScale(.large)
                            .frame(width: railWidth, height: 44)
                    }
                    .buttonStyle(.plain)
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                let newOffset = railVerticalOffset + value.translation.height
                                let maxHeight = validHeight - 200 // Leave some margin
                                let minOffset = -maxHeight * 0.4
                                let maxOffset = maxHeight * 0.4
                                railVerticalOffset = max(minOffset, min(maxOffset, newOffset))
                            }
                            .onEnded { value in
                                // Save position to UserDefaults
                                UserDefaults.standard.set(railVerticalOffset, forKey: "mailview.rail.offset")
                                
                                // Optional: Add some spring animation when drag ends
                                withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
                                    // Keep current position or add snapping logic here if desired
                                }
                            }
                    )

                    Divider().padding(.horizontal, 8)

                    // Mailbox icons
                    ForEach(availableBoxesSorted, id: \.self) { box in
                        Button {
                            self.selectedMailbox = box
                            Task {
                                // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel über Rail
                                await self.mailManager.loadCachedMails(for: box, accountId: self.selectedAccountId)
                            }
                        } label: {
                            Image(systemName: mailboxIcon(for: box))
                                .imageScale(.large)
                                .foregroundColor(box == selectedMailbox ? .accentColor : .primary)
                                .frame(width: railWidth, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: railWidth)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 1)
                .offset(y: railVerticalOffset)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.leading, 8)
            .zIndex(2)

            // Sliding panel with mailbox + accounts list
            VStack(spacing: 0) {
                List {
                    mailboxSection
                    accountsSection
                }
                .listStyle(.insetGrouped)
                .safeAreaPadding(.top)
                .safeAreaPadding(.bottom)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .frame(width: panelWidth, height: panelHeight)
            .background(.regularMaterial)
            .ignoresSafeArea()
            .offset(x: isMailboxPanelOpen ? 0 : -panelWidth)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if value.translation.width < -60 {
                            withAnimation(.easeInOut) { self.isMailboxPanelOpen = false }
                        } else if value.translation.width > 60 {
                            withAnimation(.easeInOut) { self.isMailboxPanelOpen = true }
                        }
                    }
            )
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 0)
            .zIndex(3)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List {
            mailboxSection
            accountsSection
        }
        .listStyle(SidebarListStyle())
        .navigationTitle("app.mail.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { self.activeSheet = .compose }) {
                    Image(systemName: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button(action: { Task { await self.refreshMails() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        if isBackgroundSyncing {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                    }
                }
                .disabled(self.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private var mailboxSection: some View {
        Section("app.mail.mailboxes") {
            ForEach(availableBoxesSorted, id: \.self) { box in
                MailboxRowButton(
                    box: box,
                    isSelected: selectedMailbox == box,
                    badgeCount: badgeCount(for: box),
                    onSelect: { 
                        self.selectedMailbox = box
                        Task {
                            // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel
                            await self.mailManager.loadCachedMails(for: box, accountId: self.selectedAccountId)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var accountsSection: some View {
        Section {
            ForEach(mailManager.accounts, id: \.id) { account in
                AccountRowView(
                    account: account,
                    isSelected: account.id == selectedAccountId,
                    isSyncing: mailManager.isAccountSyncing(account.id),
                    onTap: {
                        self.selectedAccountId = account.id
                        Task {
                            await self.mailManager.loadAvailableMailboxes(for: self.selectedAccountId)
                            // 🚀 Sofortiges Laden aus Cache bei Account-Wechsel  
                            await self.mailManager.loadCachedMails(for: self.selectedMailbox, accountId: account.id)
                            // Hintergrund-Sync für neuen Account
                            await self.performBackgroundSync(accountId: account.id)
                            await self.mailManager.refreshMails(for: self.selectedMailbox, accountId: account.id)
                        }
                    }
                )
            }
        }
    }
    
    @ViewBuilder
    private var detail: some View {
        // Hauptbereich mit Mail-Liste
        VStack(spacing: 0) {
            // Account-Auswahl Header
            if let accountId = selectedAccountId,
               let account = mailManager.accounts.first(where: { $0.id == accountId }) {
                AccountHeaderView(
                    account: account,
                    accountId: accountId,
                    sortMode: sortMode,
                    onSync: { id in
                        Task {
                            await self.syncAccount(id)
                            await self.refreshMails()
                        }
                    },
                    onMarkAllRead: {
                        Task { await self.markAllRead() }
                    },
                    onMarkAllUnread: {
                        Task { await self.markAllUnread() }
                    },
                    onSortByDateDesc: {
                        self.sortMode = .dateDesc
                    },
                    onSortBySender: {
                        self.sortMode = .sender
                    }
                )
                Divider()
            
            if let error = mailManager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            
            
            }
            
            
            
            // Mail-Liste
            if displayedMails.isEmpty && !isRefreshing && !isBackgroundSyncing {
                ContentUnavailableView {
                    Label("app.mail.no_messages", systemImage: mailboxIcon(for: selectedMailbox))
                } description: {
                    Text("app.mail.no_messages_description")
                } actions: {
                    Button("app.mail.refresh") {
                        Task { await self.refreshMails() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                if hSizeClass == .regular {
                    RegularSplitView(
                        mails: displayedMails,
                        selectedMailUID: $selectedMailUID,
                        searchText: $searchText,
                        onDelete: { mail in Task { await self.deleteMail(mail) } },
                        onToggleFlag: { mail in Task { await self.toggleFlag(mail, flag: "\\Flagged") } },
                        onToggleRead: { mail in Task { await self.toggleReadStatus(mail) } },
                        onRefresh: { await self.refreshMails() }
                    )
                } else {
                    // Compact width: navigate to detail
                    CompactMessageListView(
                        mails: displayedMails,
                        onDelete: { mail in Task { await self.deleteMail(mail) } },
                        onToggleFlag: { mail in Task { await self.toggleFlag(mail, flag: "\\Flagged") } },
                        onToggleRead: { mail in Task { await self.toggleReadStatus(mail) } },
                        searchText: $searchText,
                        onRefresh: { await self.refreshMails() }
                    )
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func badgeCount(for box: MailboxType) -> Int? {
        switch box {
        case .inbox:  return mailManager.unreadCount
        case .outbox: return mailManager.outboxCount
        case .drafts: return mailManager.draftsCount
        default:      return nil
        }
    }
    
    private func mailboxIcon(for type: MailboxType) -> String {
        switch type {
        case .inbox: return "tray"
        case .outbox: return "paperplane"
        case .sent: return "paperplane.fill"
        case .drafts: return "doc.text"
        case .trash: return "trash"
        case .spam: return "exclamationmark.octagon"
        }
    }
    
    private func mailboxTitle(for type: MailboxType) -> LocalizedStringKey {
        switch type {
        case .inbox: return "app.mail.inbox"
        case .outbox: return "app.mail.outbox"
        case .sent: return "app.mail.sent"
        case .drafts: return "app.mail.drafts"
        case .trash: return "app.mail.trash"
        case .spam: return "app.mail.spam"
        }
    }
    
    private func refreshMails() async {
        print("🔄 Refresh triggered for mailbox: \(selectedMailbox)")
        
        // 🚀 SOFORT: Lokale Mails aus Cache laden (ohne Wartezeit)
        print("📱 Loading cached mails immediately...")
        await mailManager.loadCachedMails(for: selectedMailbox, accountId: selectedAccountId)
        
        // 🔄 HINTERGRUND: Inkrementelle Sync parallel starten
        if let accountId = selectedAccountId {
            print("📈 Starting background incremental sync...")
            isBackgroundSyncing = true
            
            Task { @MainActor [accountId, selectedMailbox] in
                
                // Hintergrund-Sync ohne UI zu blockieren
                await performBackgroundSync(accountId: accountId)
                
                // Nach Sync: UI mit neuen Daten aktualisieren
                await mailManager.refreshMails(for: selectedMailbox, accountId: accountId)
                
                isRefreshing = false
                isBackgroundSyncing = false
            }
        } else {
            isRefreshing = false
        }
    }
    
    /// Führt Hintergrund-Synchronisation ohne UI-Blocking durch
    private func performBackgroundSync(accountId: UUID) async {
        print("🔄 Performing background sync for account: \(accountId)")
        
        // Inkrementelle Sync im Hintergrund
        MailRepository.shared.incrementalSync(accountId: accountId, folders: nil)
        
        // Kurze Wartezeit für Sync-Initiation
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 Sekunde
        
        print("✅ Background sync completed for account: \(accountId)")
    }
    
    private func syncAccount(_ accountId: UUID) async {
        await mailManager.syncAccount(accountId)
    }
    
    private func deleteMail(_ mail: MessageHeaderEntity) async {
        await mailManager.deleteMail(mail)
    }
    
    private func toggleFlag(_ mail: MessageHeaderEntity, flag: String) async {
        await mailManager.toggleFlag(mail, flag: flag)
    }
    
    private func toggleReadStatus(_ mail: MessageHeaderEntity) async {
        await mailManager.toggleReadStatus(mail)
    }
    
    private func markAllRead() async {
        await mailManager.markAllRead(in: displayedMails)
    }

    private func markAllUnread() async {
        await mailManager.markAllUnread(in: displayedMails)
    }
}

// MARK: - Data Types

enum MailSortMode: String, CaseIterable {
    case dateDesc
    case sender
}

enum MailboxType: String, CaseIterable, Hashable {
    case inbox, outbox, sent, drafts, trash, spam
}



