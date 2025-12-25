// AILO_APPApp.swift – App entry point
import SwiftUI
import AVFoundation
import UIKit

@main
struct AILO_APPApp: App {
    @StateObject private var store = DataStore()
    @State private var didRunWarmups: Bool = false

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .onAppear {
                    guard !didRunWarmups else { return }
                    didRunWarmups = true
                    StartupWarmups.run()
                }
                .onOpenURL { url in
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

    init() {
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
        TabView {
            NavigationStack { DashboardView() }
                .tabItem {
                    Image(systemName: "rectangle.grid.2x2")
                    Text("app.tab.dashboard")
                }

            NavigationStack { JourneyView() }
                .tabItem {
                    Image(systemName: "book.closed")
                    Text("app.tab.journey")
                }

            NavigationStack { MailView() }
                .tabItem {
                    Image(systemName: "envelope")
                    Text("app.tab.mail")
                }
                .badge(mailViewModel.unreadCount > 0 ? mailViewModel.unreadCount : 0)

            NavigationStack { LogsView() }
                .tabItem {
                    Image(systemName: "plus.rectangle.on.folder")
                    Text("app.tab.logs")
                }

            NavigationStack { ConfigView() }
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("app.tab.settings")
                }
        }
        .tint(.teal)
        .onAppear {
            Task {
                await mailViewModel.loadAccounts()
            }
        }
    }
}

// MARK: - AILO Startup Warmups (central place for app boot tasks)
private enum StartupWarmups {
    static func run() {
        warmAudioSession()
        warmTextKit()
        initializeDAOs()
        requestBadgePermission()
    }

    private static func requestBadgePermission() {
        Task {
            await AppBadgeManager.shared.requestPermission()
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
