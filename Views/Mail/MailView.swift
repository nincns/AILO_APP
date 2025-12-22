// MailView.swift - Zentrale Mail-Übersicht für AILO_APP (Updated)
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
    
    // MARK: - Phase 3: State-Erweiterung für Custom Folders
    @State private var selectedCustomFolder: String? = nil
    enum MailViewMode {
        case specialFolder(MailboxType)
        case customFolder(String)
    }
    @State private var viewMode: MailViewMode = .specialFolder(.inbox)
    
    @Environment(\.horizontalSizeClass) private var hSizeClass


    
    private var displayedMails: [MessageHeaderEntity] {
        // PHASE 3.3: ViewMode-basierte Mail-Auswahl
        var list: [MessageHeaderEntity]
        
        switch viewMode {
        case .specialFolder(let type):
            // Bestehende Logik: filteredMails aus MailViewModel für Special-Folders
            list = mailManager.filteredMails
        case .customFolder(let folder):
            // Custom-Folder: Verwende filteredMails da ViewModel diese jetzt korrekt setzt
            return applyFiltersAndSorting(to: mailManager.filteredMails)
        }
        
        // Für Special-Folders: Filter und Sortierung anwenden
        return applyFiltersAndSorting(to: list)
    }
    
    /// Wendet Filter und Sortierung auf eine Mail-Liste an
    private func applyFiltersAndSorting(to list: [MessageHeaderEntity]) -> [MessageHeaderEntity] {
        var filteredList = list
        
        // Apply quick filter first
        switch quickFilter {
        case .all:
            break
        case .unread:
            filteredList = filteredList.filter { $0.flags.contains("\\Seen") == false }
        case .flagged:
            filteredList = filteredList.filter { $0.flags.contains("\\Flagged") }
        }
        
        // Lightweight local search on subject/from (visual only)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            filteredList = filteredList.filter { header in
                header.subject.localizedCaseInsensitiveContains(q) || header.from.localizedCaseInsensitiveContains(q)
            }
        }
        
        // Apply sorting
        switch sortMode {
        case .dateDesc:
            filteredList = filteredList.sorted { a, b in
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
            filteredList = filteredList.sorted { a, b in
                a.from.localizedCaseInsensitiveCompare(b.from) == .orderedAscending
            }
        }
        
        return filteredList
    }

    private var availableBoxesSorted: [MailboxType] {
        let order: [MailboxType] = [.inbox, .sent, .drafts, .trash, .spam, .outbox]
        return mailManager.availableMailboxes.sorted { a, b in
            (order.firstIndex(of: a) ?? Int.max) < (order.firstIndex(of: b) ?? Int.max)
        }
    }
    
    // MARK: - Phase 3: Hilfsmethoden für MailViewMode
    
    /// Prüft ob aktuell ein Custom-Folder ausgewählt ist
    private var isCustomFolderSelected: Bool {
        if case .customFolder = viewMode {
            return true
        }
        return false
    }
    
    /// Gibt den aktuell gewählten Folder-Namen zurück (für Special- und Custom-Folders)
    private var currentFolderName: String? {
        switch viewMode {
        case .specialFolder(let mailbox):
            return mailboxFolderName(for: mailbox)
        case .customFolder(let folder):
            return folder
        }
    }
    
    /// Gibt den aktuellen Titel für die View zurück
    private var currentViewTitle: String {
        switch viewMode {
        case .specialFolder(let mailbox):
            return mailboxTitle(for: mailbox)
        case .customFolder(let folder):
            return folder
        }
    }
    
    /// Konvertiert MailboxType zu Folder-Namen (Helper)
    private func mailboxFolderName(for mailbox: MailboxType) -> String? {
        guard let accountId = selectedAccountId else { return nil }
        
        // Direkte synchrone Account-Konfiguration laden (gleiche Logik wie MailViewModel)
        let key = "mail.accounts"
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let acc = list.first(where: { $0.id == accountId }) else {
            return "INBOX" // Fallback
        }
        
        // WICHTIG: Trim whitespace! (Konsistent mit MailViewModel)
        switch mailbox {
        case .inbox:  return acc.folders.inbox.trimmingCharacters(in: .whitespacesAndNewlines)
        case .sent:   return acc.folders.sent.trimmingCharacters(in: .whitespacesAndNewlines)
        case .drafts: return acc.folders.drafts.trimmingCharacters(in: .whitespacesAndNewlines)
        case .trash:  return acc.folders.trash.trimmingCharacters(in: .whitespacesAndNewlines)
        case .spam:   return acc.folders.spam.trimmingCharacters(in: .whitespacesAndNewlines)
        case .outbox: return nil // Outbox is local-only
        }
    }



    var body: some View {
        ZStack(alignment: .leading) {
            mainNavigationContent

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
            // PHASE 3: Setze viewMode wenn selectedMailbox sich ändert  
            self.viewMode = .specialFolder(newMailbox)
            self.selectedCustomFolder = nil
            
            Task {
                // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel
                await self.mailManager.loadCachedMails(for: newMailbox, accountId: self.selectedAccountId)
            }
        }
    }

    // MARK: - Extracted Sub-Views (für Compiler Performance)

    @ViewBuilder
    private var mainNavigationContent: some View {
        NavigationStack {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerAreaView
                }
                .toolbar {
                    toolbarLeadingItems
                    toolbarTrailingItems
                }
                .toolbar(isMailboxPanelOpen ? .hidden : .visible, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var headerAreaView: some View {
        VStack(spacing: 8) {
            Text(currentViewTitle)
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

            // Suche + Optionen-Zeile unter dem Filter
            HStack(spacing: 12) {
                // Suchfeld
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Suchen", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Optionen-Menu
                optionsMenuView
            }
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()
        }
        .background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder
    private var toolbarLeadingItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Nur Account-Name oben links
            accountNameView
        }
    }

    @ViewBuilder
    private var accountNameView: some View {
        if let account = mailManager.accounts.first(where: { $0.id == selectedAccountId }) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(account.emailAddress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isBackgroundSyncing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
    }

    @ViewBuilder
    private var optionsMenuView: some View {
        Menu {
            if let accountId = selectedAccountId {
                Button {
                    Task {
                        await self.syncAccount(accountId)
                        await self.refreshMails()
                    }
                } label: {
                    Label("app.mail.sync", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
            }

            Button { Task { await self.markAllRead() } } label: {
                Label("app.mail.mark_all_read", systemImage: "envelope.open")
            }
            Button { Task { await self.markAllUnread() } } label: {
                Label("app.mail.mark_all_unread", systemImage: "envelope")
            }

            Divider()

            Button { self.sortMode = .dateDesc } label: {
                HStack {
                    Text("app.mail.sort_newest_first")
                    if sortMode == .dateDesc { Image(systemName: "checkmark") }
                }
            }
            Button { self.sortMode = .sender } label: {
                HStack {
                    Text("app.mail.sort_by_sender")
                    if sortMode == .sender { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
    }

    @ToolbarContentBuilder
    private var toolbarTrailingItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { self.activeSheet = .compose } label: {
                Image(systemName: "square.and.pencil")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await self.refreshMails() }
            } label: {
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
                            // PHASE 3: ViewMode-basierte Auswahl auch für Rail
                            self.selectedMailbox = box
                            self.viewMode = .specialFolder(box)
                            self.selectedCustomFolder = nil
                            
                            Task {
                                // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel über Rail
                                await self.mailManager.loadCachedMails(for: box, accountId: self.selectedAccountId)
                            }
                        } label: {
                            Image(systemName: mailboxIcon(for: box))
                                .imageScale(.large)
                                .foregroundColor({
                                    if case .specialFolder(let selectedBox) = viewMode, selectedBox == box {
                                        return .accentColor
                                    } else {
                                        return .primary
                                    }
                                }())
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
        // PHASE 3.2: SpecialFolders Section mit neuem Namen
        Section("Standard-Ordner") {
            ForEach(availableBoxesSorted, id: \.self) { box in
                Button {
                    // PHASE 3.2: Neues State Management mit viewMode
                    self.selectedMailbox = box
                    self.viewMode = .specialFolder(box)
                    self.selectedCustomFolder = nil
                    
                    Task {
                        // 🚀 Sofortiges Laden aus Cache bei Mailbox-Wechsel
                        await self.mailManager.loadCachedMails(for: box, accountId: self.selectedAccountId)
                    }
                } label: {
                    HStack {
                        Image(systemName: mailboxIcon(for: box))
                            .foregroundStyle(.secondary)
                        Text(mailboxTitle(for: box))
                            .foregroundStyle(.primary)
                        Spacer()
                        
                        // Badge für ungelesene Nachrichten
                        if let count = badgeCount(for: box), count > 0 {
                            Text("\(count)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)  // Für sauberes List-Design
                .listRowBackground(
                    // Highlight wenn dieser Mailbox gewählt ist
                    {
                        if case .specialFolder(let selectedBox) = viewMode, selectedBox == box {
                            return Color.accentColor.opacity(0.15)
                        } else {
                            return Color.clear
                        }
                    }()
                )
            }
        }
        
        // PHASE 3.2: Custom-Folders Section (nur wenn verfügbar)
        if !mailManager.allServerFolders.isEmpty {
            Section("Weitere Ordner") {
                ForEach(mailManager.allServerFolders, id: \.self) { folder in
                    Button {
                        // PHASE 3.2: Custom-Folder auswählen
                        selectedCustomFolder = folder
                        viewMode = .customFolder(folder)
                        selectedMailbox = .inbox  // Fallback für legacy code
                        
                        Task {
                            // Custom-Folder laden - nur wenn accountId verfügbar ist
                            guard let accountId = selectedAccountId else {
                                print("❌ No accountId available for loading custom folder")
                                return
                            }
                            await mailManager.loadMailsForFolder(folder: folder, accountId: accountId)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder)
                                .foregroundStyle(.primary)
                            Spacer()
                            
                            // Optional: Badge für ungelesene Nachrichten in Custom-Folders
                            // (Kann später implementiert werden)
                        }
                    }
                    .buttonStyle(.plain)  // Für sauberes List-Design
                    .listRowBackground(
                        // Highlight wenn dieser Custom-Folder gewählt ist
                        selectedCustomFolder == folder ? 
                        Color.accentColor.opacity(0.15) : 
                        Color.clear
                    )
                }
            }
        }
        
        // PHASE 3.2: Loading-Indicator für Folder-Discovery
        if mailManager.isLoadingFolders {
            Section {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Ordner werden geladen…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            // Fehleranzeige (falls vorhanden)
            if let error = mailManager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
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
                    .environmentObject(mailManager)  // ✅ NEU: EnvironmentObject hinzugefügt
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
    
    private func mailboxTitle(for type: MailboxType) -> String {
        switch type {
        case .inbox: return String(localized: "app.mail.inbox")
        case .outbox: return String(localized: "app.mail.outbox")
        case .sent: return String(localized: "app.mail.sent")
        case .drafts: return String(localized: "app.mail.drafts")
        case .trash: return String(localized: "app.mail.trash")
        case .spam: return String(localized: "app.mail.spam")
        }
    }
    
    private func refreshMails() async {
        print("🔄 Refresh triggered for viewMode: \(viewMode)")
        
        guard let accountId = selectedAccountId else {
            print("❌ No accountId for refresh")
            return
        }
        
        // PHASE 3.2: Behandle beide ViewMode Cases
        switch viewMode {
        case .specialFolder(let mailbox):
            print("🔄 Refreshing special folder: \(mailbox)")
            
            // 🚀 SOFORT: Lokale Mails aus Cache laden (ohne Wartezeit)
            print("📱 Loading cached mails immediately...")
            await mailManager.loadCachedMails(for: mailbox, accountId: accountId)
            
            // 🔄 HINTERGRUND: Inkrementelle Sync parallel starten
            print("📈 Starting background incremental sync...")
            isBackgroundSyncing = true
            
            Task { @MainActor [accountId, mailbox] in
                
                // Hintergrund-Sync ohne UI zu blockieren
                await performBackgroundSync(accountId: accountId)
                
                // Nach Sync: UI mit neuen Daten aktualisieren
                await mailManager.refreshMails(for: mailbox, accountId: accountId)
                
                self.isBackgroundSyncing = false
                print("✅ Background sync completed for special folder: \(mailbox)")
            }
            
        case .customFolder(let folder):
            print("🔄 Refreshing custom folder: '\(folder)'")
            
            // Custom-Folder haben keinen separaten Cache-Loader, nutze direkte Methode
            await mailManager.loadMailsForFolder(folder: folder, accountId: accountId)
            
            print("✅ Custom folder refresh completed: '\(folder)'")
        }
    }
    
    /// Führt Hintergrund-Synchronisation ohne UI-Blocking durch
    private func performBackgroundSync(accountId: UUID) async {
        print("🔄 Performing background sync for account: \(accountId)")
        
        // PHASE 4: Alle konfigurierten Ordner synchronisieren
        let allFolders = MailRepository.shared.getAllConfiguredFolders(accountId: accountId)
        print("📁 Syncing all configured folders: \(allFolders)")
        
        // Inkrementelle Sync im Hintergrund für alle Ordner
        MailRepository.shared.incrementalSync(accountId: accountId, folders: allFolders)
        
        // Kurze Wartezeit für Sync-Initiation
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 Sekunde
        
        print("✅ Background sync completed for account: \(accountId) - synced \(allFolders.count) folders")
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



