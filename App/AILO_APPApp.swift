// AILO_APPApp.swift â€“ App entry point
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
    var body: some View {
        TabView {
            NavigationStack { DashboardView() }
                .tabItem {
                    Image(systemName: "rectangle.grid.2x2")
                    Text("app.tab.dashboard")
                }

            NavigationStack { MailView() }  // â† NEU
                .tabItem {
                    Image(systemName: "envelope")  // â† Mail-Icon
                    Text("app.tab.mail")           // â† Lokalisierung
                }

            NavigationStack { SchreibenView() }
                .tabItem {
                    Image(systemName: "square.and.pencil")
                    Text("app.tab.write")
                }

            NavigationStack { SprechenView() }
                .tabItem {
                    Image(systemName: "mic")
                    Text("app.tab.speak")
                }

            NavigationStack { LogsView() }
                .tabItem {
                    Image(systemName: "clock")
                    Text("app.tab.logs")
                }
        }
    }
}

// MARK: - AILO Startup Warmups (central place for app boot tasks)
private enum StartupWarmups {
    static func run() {
        warmAudioSession()
        warmTextKit()
        initializeDAOs()  // â† UPDATED
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
        let dbURL = docsDir.appendingPathComponent("mail_v3.db")  // âœ… v3 fÃ¼r frische DB

        print("ðŸ’¾ DEBUG: Using DB at: \(dbURL.path)")

        // âœ… TEMPORÃ„R: Cleanup alter DBs fÃ¼r frischen Start
        let oldURLs = [
            docsDir.appendingPathComponent("mail.db"),
            docsDir.appendingPathComponent("mail_v2.db"),
            dbURL  // auch v3 cleanen fÃ¼r ganz frisch
        ]
        for oldURL in oldURLs {
            let walURL = oldURL.deletingPathExtension().appendingPathExtension("db-wal")
            let shmURL = oldURL.deletingPathExtension().appendingPathExtension("db-shm")
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)
        }
        print("ðŸ§¹ DEBUG: Cleaned up all old database files")

        do {
            let daoFactory = DAOFactory(dbPath: dbURL.path)
            print("ðŸ”§ DEBUG: Attempting to initialize database at: \(dbURL.path)")
            
            try daoFactory.initializeDatabase()
            print("ðŸ”§ DEBUG: Database initialization successful")
            
            // Test the schema
            let schemaInfo = try daoFactory.validateSchema()
            print("ðŸ”§ DEBUG: Database user version: \(schemaInfo.userVersion)")
            print("ðŸ”§ DEBUG: Folders table exists: \(schemaInfo.foldersTableExists)")
            
            // WICHTIG: Store the factory in MailRepository to prevent deallocation
            MailRepository.shared.factory = daoFactory
            // Use the combined DAO that provides both read and write capabilities
            MailRepository.shared.dao = daoFactory.mailFullAccessDAO
            MailRepository.shared.writeDAO = daoFactory.mailFullAccessDAO  // ← FEHLT!
            print("âœ… DEBUG: DAO Factory initialized successfully with fresh DB!")
            
            // ðŸš€ NEU: Starte initiale Mail-Synchronisation im Hintergrund
            Task {
                await startInitialMailSync()
            }
        } catch {
            print("âŒ DEBUG: DAO initialization failed: \(error)")
            print("âŒ DEBUG: Error type: \(type(of: error))")
            if let daoError = error as? DAOError {
                print("âŒ DEBUG: DAO Error details: \(daoError.localizedDescription)")
            }
            // Print the full error details
            print("âŒ DEBUG: Full error: \(String(describing: error))")
            
            // Fallback: Continue without DAO (app should still work in limited mode)
            MailRepository.shared.dao = nil
        }
    }
    
    /// Startet die initiale Mail-Synchronisation fÃ¼r alle aktiven Accounts
    private static func startInitialMailSync() async {
        print("ðŸš€ Starting initial mail sync on app startup...")
        
        // Lade aktive Accounts
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            print("ðŸ“§ No mail accounts found for initial sync")
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
            print("ðŸ“§ No active mail accounts found for initial sync")
            return
        }
        
        print("ðŸ”„ Starting background sync for \(activeAccounts.count) active accounts...")
        
        // Starte inkrementelle Sync fÃ¼r alle aktiven Accounts parallel
        await withTaskGroup(of: Void.self) { group in
            for account in activeAccounts {
                group.addTask {
                    print("ðŸ“ˆ Starting incremental sync for account: \(account.accountName)")
                    await MailRepository.shared.incrementalSync(accountId: account.id, folders: nil)
                    
                    // Kurze Wartezeit fÃ¼r Sync-Initiation
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 Sekunden
                    
                    print("âœ… Initial sync completed for account: \(account.accountName)")
                }
            }
        }
        
        print("ðŸŽ‰ Initial mail sync startup completed for all accounts!")
    }
}
