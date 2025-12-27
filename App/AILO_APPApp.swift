// AILO_APPApp.swift – App entry point
import SwiftUI
import AVFoundation
import UIKit

@main
struct AILO_APPApp: App {
    @StateObject private var store = DataStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var didRunWarmups: Bool = false
    @State private var pendingImportFileURL: URL?

    init() {
        // Register background tasks BEFORE app finishes launching
        BackgroundTaskManager.shared.registerTasks()

        // Setup notification categories for mail alerts
        AILONotificationService.shared.setupCategories()
    }

    var body: some Scene {
        WindowGroup {
            MainView(pendingImportFileURL: $pendingImportFileURL)
                .environmentObject(store)
                .onAppear {
                    guard !didRunWarmups else { return }
                    didRunWarmups = true
                    StartupWarmups.run()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        print("📬 [App] Entering background - scheduling tasks")
                        BackgroundTaskManager.shared.scheduleAppRefresh()
                        BackgroundTaskManager.shared.scheduleProcessingTask()
                    case .active:
                        print("📬 [App] App became active")
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                .onOpenURL { url in
                    // Handle .ailo file URLs
                    if url.pathExtension.lowercased() == "ailo" {
                        pendingImportFileURL = url
                        return
                    }

                    // Handle ailo:// URL scheme
                    guard url.scheme == "ailo" else { return }
                    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let host = url.host?.lowercased() ?? ""
                    if host == "import" {
                        if let textItem = comps?.queryItems?.first(where: { $0.name == "text" })?.value,
                           let decoded = textItem.removingPercentEncoding {
                            store.pendingImportText = decoded
                        }
                    }
                }
        }
    }
}

struct MainView: View {
    @StateObject private var mailViewModel = MailViewModel()
    @Binding var pendingImportFileURL: URL?
    @State private var showImportSheet = false
    @State private var selectedTab: Int = 0
    @State private var pendingDeepLink: AILONotification.DeepLink?

    // First-Run Assistant
    @AppStorage("hasCompletedFirstRun") private var hasCompletedFirstRun: Bool = false
    @AppStorage("showAssistantOnStartup") private var showAssistantOnStartup: Bool = true
    @State private var showFirstRunAssistant: Bool = false
    @State private var showNoAccountsAssistant: Bool = false

    init(pendingImportFileURL: Binding<URL?> = .constant(nil)) {
        self._pendingImportFileURL = pendingImportFileURL

        // Customize tab bar badge appearance to teal
        let tealColor = UIColor.systemTeal
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.stackedLayoutAppearance.normal.badgeBackgroundColor = tealColor
        appearance.stackedLayoutAppearance.selected.badgeBackgroundColor = tealColor
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { DashboardView() }
                .tabItem {
                    Image(systemName: "rectangle.grid.2x2")
                    Text("app.tab.dashboard")
                }
                .tag(0)

            NavigationStack { JourneyView() }
                .tabItem {
                    Image(systemName: "book.closed")
                    Text("app.tab.journey")
                }
                .tag(1)

            NavigationStack { MailView() }
                .tabItem {
                    Image(systemName: "envelope")
                    Text("app.tab.mail")
                }
                .badge(mailViewModel.unreadCount > 0 ? mailViewModel.unreadCount : 0)
                .tag(2)

            NavigationStack { LogsView() }
                .tabItem {
                    Image(systemName: "plus.rectangle.on.folder")
                    Text("app.tab.logs")
                }
                .tag(3)

            NavigationStack { ConfigView() }
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("app.tab.settings")
                }
                .tag(4)
        }
        .tint(.teal)
        .onAppear {
            Task {
                await mailViewModel.loadAccounts()
            }
            // Show first-run assistant if not completed
            if !hasCompletedFirstRun {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showFirstRunAssistant = true
                }
            } else if showAssistantOnStartup && !hasMailAccounts() {
                // Show assistant if enabled and no mail accounts exist
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showNoAccountsAssistant = true
                }
            }
        }
        .sheet(isPresented: $showFirstRunAssistant, onDismiss: {
            hasCompletedFirstRun = true
        }) {
            AssistantView(isFirstRun: true)
        }
        .sheet(isPresented: $showNoAccountsAssistant) {
            AssistantView()
        }
        .onChange(of: pendingImportFileURL) { _, newURL in
            if newURL != nil {
                showImportSheet = true
            }
        }
        .sheet(isPresented: $showImportSheet, onDismiss: {
            pendingImportFileURL = nil
        }) {
            JourneyImportSheet(url: pendingImportFileURL)
                .environmentObject(JourneyStore.shared)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ailoDeepLinkNavigation)) { notification in
            guard let deepLink = notification.userInfo?["deepLink"] as? AILONotification.DeepLink else { return }
            handleDeepLink(deepLink)
        }
    }

    // MARK: - Helpers

    /// Checks if any mail accounts are configured
    private func hasMailAccounts() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            return false
        }
        return !accounts.isEmpty
    }

    // MARK: - Deep Link Navigation

    private func handleDeepLink(_ deepLink: AILONotification.DeepLink) {
        print("🔗 [DeepLink] Handling: \(deepLink)")

        switch deepLink {
        case .mail(let accountId, let folder, let uid):
            // Navigate to mail tab
            selectedTab = 2
            // Store pending deep link for MailView to pick up
            pendingDeepLink = deepLink
            print("🔗 [DeepLink] Navigating to mail: account=\(accountId.uuidString.prefix(8)), folder=\(folder), uid=\(uid)")

        case .journey(let nodeId):
            // Navigate to journey tab
            selectedTab = 1
            pendingDeepLink = deepLink
            print("🔗 [DeepLink] Navigating to journey node: \(nodeId)")

        case .log(let entryId):
            // Navigate to logs tab
            selectedTab = 3
            pendingDeepLink = deepLink
            // Post notification for LogsView to pick up
            NotificationCenter.default.post(
                name: .navigateToLogEntry,
                object: nil,
                userInfo: ["entryId": entryId]
            )
            print("🔗 [DeepLink] Navigating to log entry: \(entryId)")

        case .none:
            break
        }
    }
}

// MARK: - AILO Startup Warmups (central place for app boot tasks)
private enum StartupWarmups {
    static func run() {
        warmAudioSession()
        warmTextKit()
        initializeDAOs()
        requestNotificationPermission()
    }

    private static func requestNotificationPermission() {
        Task {
            // Request permission for notifications (includes badge)
            _ = await AILONotificationService.shared.requestPermission()
        }
    }

    private static func warmAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private static func warmTextKit() {
        DispatchQueue.main.async {
            let tv = UITextView(frame: .zero)
            tv.text = " "
            _ = tv.layoutManager
        }
    }
    
    private static func initializeDAOs() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbURL = docsDir.appendingPathComponent("mail_v3.db")

        print("💾 DEBUG: Using DB at: \(dbURL.path)")

        // ✅ TEMPORÄR DEAKTIVIERT: Cleanup alter DBs für frischen Start
        // Bei Bedarf wieder aktivieren für Troubleshooting
        /*
        let oldURLs = [
            docsDir.appendingPathComponent("mail.db"),
            docsDir.appendingPathComponent("mail_v2.db"),
            dbURL  // auch v3 cleanen für ganz frisch
        ]
        for oldURL in oldURLs {
            let walURL = oldURL.deletingPathExtension().appendingPathExtension("db-wal")
            let shmURL = oldURL.deletingPathExtension().appendingPathExtension("db-shm")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
        }
        print("🧹 DEBUG: Cleaned up all old database files")
        */

        do {
            let daoFactory = DAOFactory(dbPath: dbURL.path)
            print("🔧 DEBUG: Attempting to initialize database at: \(dbURL.path)")
            
            try daoFactory.initializeDatabase()
            print("🔧 DEBUG: Database initialization successful")
            
            // Test the schema
            let schemaInfo = try daoFactory.validateSchema()
            print("🔧 DEBUG: Database user version: \(schemaInfo.userVersion)")
            print("🔧 DEBUG: Folders table exists: \(schemaInfo.foldersTableExists)")
            
            // WICHTIG: Store the factory in MailRepository to prevent deallocation
            MailRepository.shared.factory = daoFactory
            // Use the combined DAO that provides both read and write capabilities
            MailRepository.shared.dao = daoFactory.mailFullAccessDAO
            MailRepository.shared.writeDAO = daoFactory.mailFullAccessDAO
            print("✅ DEBUG: DAO Factory initialized successfully with fresh DB!")

            // ✅ MailSendService initialisieren
            initializeMailSendService(daoFactory: daoFactory)
            print("✅ MailSendService initialized with OutboxDAO and SMTP config")

            // 🚀 NEU: Starte initiale Mail-Synchronisation im Hintergrund
            Task {
                await startInitialMailSync()
            }
        } catch {
            print("❌ DEBUG: DAO initialization failed: \(error)")
            print("❌ DEBUG: Error type: \(type(of: error))")
            if let daoError = error as? DAOError {
                print("❌ DEBUG: DAO Error details: \(daoError.localizedDescription)")
            }
            // Print the full error details
            print("❌ DEBUG: Full error: \(String(describing: error))")
            
            // Fallback: Continue without DAO (app should still work in limited mode)
            MailRepository.shared.dao = nil
        }
    }
    
    /// Startet die initiale Mail-Synchronisation für alle aktiven Accounts
    private static func startInitialMailSync() async {
        print("🚀 Starting initial mail sync on app startup...")
        
        // Lade aktive Accounts
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            print("🔧 No mail accounts found for initial sync")
            return
        }
        
        let activeKey = "mail.accounts.active"
        let activeIDs: Set<UUID> = {
            if let data = UserDefaults.standard.data(forKey: activeKey),
               let arr = try? JSONDecoder().decode([UUID].self, from: data) {
                return Set(arr)
            }
            return []
        }()
        
        let activeAccounts = accounts.filter { activeIDs.contains($0.id) }
        
        if activeAccounts.isEmpty {
            print("🔧 No active mail accounts found for initial sync")
            return
        }
        
        print("🔄 Starting background sync for \(activeAccounts.count) active accounts...")
        
        // Starte inkrementelle Sync für alle aktiven Accounts parallel
        await withTaskGroup(of: Void.self) { group in
            for account in activeAccounts {
                group.addTask {
                    print("📈 Starting incremental sync for account: \(account.accountName)")
                    await MailRepository.shared.incrementalSync(accountId: account.id, folders: nil)
                    
                    // Kurze Wartezeit für Sync-Initiation
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 Sekunden
                    
                    print("✅ Initial sync completed for account: \(account.accountName)")
                }
            }
        }
        
        print("🎉 Initial mail sync startup completed for all accounts!")

        // Update app badge with initial unread count
        await updateInitialBadgeCount(accounts: activeAccounts)
    }

    /// Updates app badge with total unread count after initial sync
    private static func updateInitialBadgeCount(accounts: [MailAccountConfig]) async {
        var totalUnread = 0
        for account in accounts {
            if let headers = try? MailRepository.shared.listHeaders(accountId: account.id, folder: "INBOX", limit: 1000, offset: 0) {
                totalUnread += headers.filter { !$0.flags.contains("\\Seen") }.count
            }
        }
        await AppBadgeManager.shared.updateFromUnreadCount(totalUnread)
        print("📛 Initial badge count set to: \(totalUnread)")
    }

    /// Initialisiert den MailSendService mit DAO und SMTP-Konfiguration
    private static func initializeMailSendService(daoFactory: DAOFactory) {
        MailSendService.shared.dao = OutboxDAOAdapter(daoFactory.outboxDAO)
        MailSendService.shared.smtpFactory = { NIOSMTPClient() }
        MailSendService.shared.smtpConfigProvider = { accountId in
            guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
                  let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
                  let acc = accounts.first(where: { $0.id == accountId }) else {
                return nil
            }
            let encryption: SMTPTLSEncryption = {
                // Port 587 = STARTTLS (erst Plaintext, dann TLS-Upgrade)
                // Port 465 = direktes SSL/TLS
                if acc.smtpPort == 587 {
                    return .startTLS
                }
                if acc.smtpPort == 465 {
                    return .sslTLS
                }
                // Fallback auf Account-Einstellung
                switch acc.smtpEncryption {
                case .none: return .plain
                case .sslTLS: return .sslTLS
                case .startTLS: return .startTLS
                }
            }()
            // Handle optional smtpPassword
            let username = acc.smtpUsername.isEmpty ? acc.recvUsername : acc.smtpUsername
            let password = (acc.smtpPassword ?? "").isEmpty ? acc.recvPassword : (acc.smtpPassword ?? "")
            return SMTPConfig(
                host: acc.smtpHost,
                port: acc.smtpPort,
                encryption: encryption,
                heloName: nil,
                username: username,
                password: password
            )
        }
    }
}
