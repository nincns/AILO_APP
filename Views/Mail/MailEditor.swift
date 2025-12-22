extension Notification.Name {
    static let mailAccountsDidChange = Notification.Name("mail.accounts.changed")
}

fileprivate enum MailStorageEditorHelper {
    static let key = "mail.accounts"
    static func load() -> [MailAccountConfig] {
        if let data = UserDefaults.standard.data(forKey: key) {
            return (try? JSONDecoder().decode([MailAccountConfig].self, from: data)) ?? []
        }
        return []
    }
    static func save(_ accounts: [MailAccountConfig]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}


import Security
import Foundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

struct MailEditor: View {
    let existingConfig: MailAccountConfig?
    @State private var existingId: UUID? = nil

    var body: some View {
        Form {
            Section(header: Text(String(localized: "mail.editor.section.account"))) {
                TextField(String(localized: "mail.editor.accountName"), text: $accountName)
                TextField(String(localized: "mail.editor.displayName"), text: $displayName)
                TextField(String(localized: "mail.editor.replyTo"), text: $replyTo)
            }

            Section(header: Text(String(localized: "mail.editor.section.incoming"))) {
                Picker(String(localized: "mail.editor.recv.protocol"), selection: $recvProtocol) {
                    ForEach(ReceiveProtocol.allCases) { p in Text(p.rawValue).tag(p) }
                }
                Picker(String(localized: "mail.editor.recv.encryption"), selection: $recvEnc) {
                    ForEach(Encryption.allCases) { e in Text(e.rawValue).tag(e) }
                }
                TextField(String(localized: "mail.editor.recv.host"), text: $recvHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $recvPort, in: 1...65535) {
                    HStack { Text(String(localized: "mail.editor.recv.port")); Spacer(); Text("\(recvPort)") }
                }
                TextField(String(localized: "mail.editor.recv.user"), text: $recvUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(String(localized: "mail.editor.recv.password"), text: $recvPassword)
            }

            Section(header: Text(String(localized: "mail.editor.section.outgoing"))) {
                Picker(String(localized: "mail.editor.smtp.encryption"), selection: $smtpEnc) {
                    ForEach(Encryption.allCases) { e in Text(e.rawValue).tag(e) }
                }
                TextField(String(localized: "mail.editor.smtp.host"), text: $smtpHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(value: $smtpPort, in: 1...65535) {
                    HStack { Text(String(localized: "mail.editor.smtp.port")); Spacer(); Text("\(smtpPort)") }
                }
                TextField(String(localized: "mail.editor.smtp.user"), text: $smtpUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(String(localized: "mail.editor.smtp.password"), text: $smtpPassword)
            }

            Section(header: Text(String(localized: "mail.editor.section.advanced"))) {
                Picker(String(localized: "mail.editor.authMethod"), selection: $authMethod) {
                    Text("Password").tag("Password")
                    Text("OAuth2").tag("OAuth2")
                    Text("App Password").tag("AppPassword")
                }
                Stepper(value: $timeoutSeconds, in: 5...120) {
                    HStack { Text(String(localized: "mail.editor.timeout")); Spacer(); Text("\(timeoutSeconds)s") }
                }
                Toggle(String(localized: "mail.editor.logging"), isOn: $connectionLogging)
                Toggle(String(localized: "mail.editor.interval.enabled"), isOn: $intervalActive)
                Stepper(value: $checkIntervalMin, in: 1...120) {
                    HStack { Text(String(localized: "mail.editor.interval.min")); Spacer(); Text("\(checkIntervalMin) min") }
                }
                .disabled(!intervalActive)

                // Folders
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "mail.editor.folders"))
                        .font(.headline)
                    TextField("INBOX", text: $folderInbox)
                    TextField("Sent", text: $folderSent)
                    TextField("Drafts", text: $folderDrafts)
                    TextField("Trash", text: $folderTrash)
                    TextField("Spam", text: $folderSpam)
                    Divider()
                    Button {
                        Task { await fetchFolders() }
                    } label: {
                        if isFetchingFolders { ProgressView() } else { Text(String(localized: "mail.editor.action.fetchFolders")) }
                    }
                    .disabled(isFetchingFolders || recvHost.isEmpty || recvUser.isEmpty || recvProtocol != .imap)
                }
            }

            // S/MIME Signing Section
            Section(header: Text(String(localized: "smime.section.title"))) {
                Toggle(String(localized: "smime.signing.enabled"), isOn: $signingEnabled)

                if signingEnabled {
                    Picker(String(localized: "smime.certificate.select"), selection: $signingCertificateId) {
                        Text(String(localized: "smime.certificate.none")).tag("")
                        ForEach(availableCertificates) { cert in
                            Text(cert.displayName).tag(cert.id)
                        }
                    }

                    if !signingCertificateId.isEmpty,
                       let cert = availableCertificates.first(where: { $0.id == signingCertificateId }) {
                        HStack {
                            Text(String(localized: "smime.certificate.email"))
                            Spacer()
                            Text(cert.email ?? "-").foregroundColor(.secondary)
                        }
                        if let expiry = cert.expiresAt {
                            HStack {
                                Text(String(localized: "smime.certificate.expires"))
                                Spacer()
                                Text(expiry, style: .date).foregroundColor(.secondary)
                            }
                        }
                    }

                    // Import Button
                    Button {
                        showP12Importer = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text(String(localized: "smime.import.button"))
                        }
                    }

                    if availableCertificates.isEmpty {
                        Text(String(localized: "smime.certificate.not_found"))
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(Text(String(localized: "mail.editor.title")))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "common.save")) { saveAccount() }
                    .disabled(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recvHost.isEmpty || smtpHost.isEmpty)
            }
        }
        .onChange(of: recvProtocol) { _, _ in updateDefaultIncomingPort() }
        .onChange(of: recvEnc) { _, _ in updateDefaultIncomingPort() }
        .onChange(of: smtpEnc) { _, _ in updateDefaultSmtpPort() }
        .onAppear {
            prefillIfNeeded()
            availableCertificates = KeychainCertificateService.shared.listSigningCertificates()
        }
        .alert(String(localized: "mail.editor.test.title"), isPresented: $showTestAlert) {
            Button("OK", role: .cancel) { isFetchingFolders = false }
        } message: {
            Text(testMessage)
        }
        // P12 File Importer
        .fileImporter(
            isPresented: $showP12Importer,
            allowedContentTypes: [.pkcs12],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // Zugriff auf die Datei starten
                guard url.startAccessingSecurityScopedResource() else {
                    importErrorMessage = String(localized: "smime.import.error.access")
                    showImportError = true
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }

                do {
                    pendingP12Data = try Data(contentsOf: url)
                    p12Password = ""
                    showP12PasswordAlert = true
                } catch {
                    importErrorMessage = error.localizedDescription
                    showImportError = true
                }
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }
        // P12 Password Alert
        .alert(String(localized: "smime.import.password.title"), isPresented: $showP12PasswordAlert) {
            SecureField(String(localized: "smime.import.password.placeholder"), text: $p12Password)
            Button(String(localized: "common.cancel"), role: .cancel) {
                pendingP12Data = nil
                p12Password = ""
            }
            Button(String(localized: "smime.import.action")) {
                importP12Certificate()
            }
        } message: {
            Text(String(localized: "smime.import.password.message"))
        }
        // Import Error Alert
        .alert(String(localized: "smime.import.error.title"), isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importErrorMessage)
        }
        // Import Success Alert
        .alert(String(localized: "smime.import.success.title"), isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(String(localized: "smime.import.success.message"))
        }
    }

    // MARK: - P12 Import

    private func importP12Certificate() {
        guard let data = pendingP12Data else { return }

        let result = KeychainCertificateService.shared.importP12(data: data, password: p12Password)

        // Cleanup
        pendingP12Data = nil
        p12Password = ""

        switch result {
        case .success(let certInfo):
            // Refresh certificate list
            availableCertificates = KeychainCertificateService.shared.listSigningCertificates()
            // Auto-select the imported certificate
            signingCertificateId = certInfo.id
            showImportSuccess = true

        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    init(existing: MailAccountConfig? = nil) {
        self.existingConfig = existing
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: - Model (local state, can be wired to DataStore later)
    @State private var accountName: String = ""
    @State private var showTestAlert: Bool = false
    @State private var testMessage: String = ""
    @State private var isFetchingFolders: Bool = false

    @State private var intervalActive: Bool = false

    @State private var showAdvanced: Bool = false
    @State private var displayName: String = ""
    @State private var replyTo: String = ""
    @State private var authMethod: String = "Password"
    @State private var timeoutSeconds: Int = 30
    @State private var connectionLogging: Bool = false

    @State private var folderInbox: String = ""
    @State private var folderSent: String = ""
    @State private var folderDrafts: String = ""
    @State private var folderTrash: String = ""
    @State private var folderSpam: String = ""

    enum ReceiveProtocol: String, CaseIterable, Identifiable { case imap = "IMAP", pop3 = "POP3"; var id: String { rawValue } }
    enum Encryption: String, CaseIterable, Identifiable { case none = "None", sslTLS = "SSL/TLS", startTLS = "STARTTLS"; var id: String { rawValue } }

    // Incoming (IMAP/POP3)
    @State private var recvProtocol: ReceiveProtocol = .imap
    @State private var recvHost: String = ""
    @State private var recvPort: Int = 993
    @State private var recvUser: String = ""
    @State private var recvPassword: String = ""
    @State private var recvEnc: Encryption = .sslTLS

    // Outgoing (SMTP)
    @State private var smtpHost: String = ""
    @State private var smtpPort: Int = 587
    @State private var smtpUser: String = ""
    @State private var smtpPassword: String = ""
    @State private var smtpEnc: Encryption = .startTLS

    // Check interval in minutes while app is active
    @State private var checkIntervalMin: Int = 15

    // S/MIME Signing
    @State private var signingEnabled: Bool = false
    @State private var signingCertificateId: String = ""
    @State private var availableCertificates: [SigningCertificateInfo] = []

    // P12 Import
    @State private var showP12Importer: Bool = false
    @State private var showP12PasswordAlert: Bool = false
    @State private var p12Password: String = ""
    @State private var pendingP12Data: Data? = nil
    @State private var showImportError: Bool = false
    @State private var importErrorMessage: String = ""
    @State private var showImportSuccess: Bool = false

    // MARK: - Prefill & Save
    private func prefillIfNeeded() {
        guard let incoming = existingConfig else { return }
        // Prefer the locally persisted replica (may contain updated special folders)
        let persistedList = MailStorageEditorHelper.load()
        let cfg = persistedList.first(where: { $0.id == incoming.id }) ?? incoming
        existingId = cfg.id
        accountName = cfg.accountName
        displayName = cfg.displayName ?? ""
        replyTo = cfg.replyTo ?? ""
        // Incoming
        recvProtocol = (cfg.recvProtocol == .imap) ? .imap : .pop3
        recvHost = cfg.recvHost
        recvPort = cfg.recvPort
        recvEnc = {
            switch cfg.recvEncryption {
            case .none: return .none
            case .sslTLS: return .sslTLS
            case .startTLS: return .startTLS
            }
        }()
        recvUser = cfg.recvUsername
        recvPassword = cfg.recvPassword ?? ""
        // Outgoing
        smtpHost = cfg.smtpHost
        smtpPort = cfg.smtpPort
        smtpEnc = {
            switch cfg.smtpEncryption {
            case .none: return .none
            case .sslTLS: return .sslTLS
            case .startTLS: return .startTLS
            }
        }()
        smtpUser = cfg.smtpUsername
        smtpPassword = cfg.smtpPassword ?? ""
        // Advanced
        authMethod = {
            switch cfg.authMethod {
            case .password: return "Password"
            case .oauth2: return "OAuth2"
            case .appPassword: return "AppPassword"
            }
        }()
        timeoutSeconds = cfg.connectionTimeoutSec
        connectionLogging = cfg.enableLogging
        intervalActive = cfg.checkIntervalEnabled
        checkIntervalMin = cfg.checkIntervalMin ?? checkIntervalMin
        // Folders
        folderInbox = cfg.folders.inbox
        folderSent = cfg.folders.sent
        folderDrafts = cfg.folders.drafts
        folderTrash = cfg.folders.trash
        folderSpam = cfg.folders.spam

        // S/MIME Signing
        signingEnabled = cfg.signingEnabled
        signingCertificateId = cfg.signingCertificateId ?? ""

        // Prefer DAO values only when they are meaningful (avoid overwriting with mere defaults)
        if let factory = MailRepository.shared.factory, let map = try? factory.mailReadDAO.specialFolders(accountId: cfg.id) {
            folderInbox  = preferDaoValue(map["inbox"],  over: cfg.folders.inbox,  default: "INBOX")
            folderSent   = preferDaoValue(map["sent"],   over: cfg.folders.sent,   default: "Sent")
            folderDrafts = preferDaoValue(map["drafts"], over: cfg.folders.drafts, default: "Drafts")
            folderTrash  = preferDaoValue(map["trash"],  over: cfg.folders.trash,  default: "Trash")
            folderSpam   = preferDaoValue(map["spam"],   over: cfg.folders.spam,   default: "Spam")
        }
    }

    private func saveAccount() {
        print("🔧 DEBUG: Starting saveAccount()")
        
        do {
            var list = MailStorageEditorHelper.load()
            let id = existingId ?? UUID()
            
            print("🔧 DEBUG: Account ID: \(id)")
            print("🔧 DEBUG: Account Name: '\(accountName)'")
            
            let recvEncModel: MailEncryption = {
                switch recvEnc {
                case .none: return .none
                case .sslTLS: return .sslTLS
                case .startTLS: return .startTLS
                }
            }()
            
            let smtpEncModel: MailEncryption = {
                switch smtpEnc {
                case .none: return .none
                case .sslTLS: return .sslTLS
                case .startTLS: return .startTLS
                }
            }()
            
            let protoModel: MailProtocol = (recvProtocol == .imap) ? .imap : .pop3
            let authModel: MailAuthMethod = {
                switch authMethod.lowercased() {
                case "oauth2": return .oauth2
                case "apppassword": return .appPassword
                default: return .password
                }
            }()

            print("🔧 DEBUG: Creating MailAccountConfig...")
            
            // Validate critical fields before creating config
            guard !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("❌ ERROR: Account name is empty")
                return
            }
            
            guard !recvHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("❌ ERROR: Receive host is empty")
                return
            }
            
            guard !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("❌ ERROR: SMTP host is empty") 
                return
            }
            
            // Sanitize timeout values
            let safeTimeoutSeconds = max(5, min(120, timeoutSeconds))
            let safeCheckInterval = max(1, min(120, checkIntervalMin))
            
            print("🔧 DEBUG: Using timeout: \(safeTimeoutSeconds)s, interval: \(safeCheckInterval)min")
            
            let cfg = MailAccountConfig(
                id: id,
                accountName: accountName,
                displayName: displayName.isEmpty ? nil : displayName,
                replyTo: replyTo.isEmpty ? nil : replyTo,
                signingEnabled: signingEnabled,
                signingCertificateId: signingCertificateId.isEmpty ? nil : signingCertificateId,
                recvProtocol: protoModel,
                recvHost: recvHost,
                recvPort: recvPort,
                recvEncryption: recvEncModel,
                recvUsername: recvUser,
                recvPassword: recvPassword.isEmpty ? nil : recvPassword,
                smtpHost: smtpHost,
                smtpPort: smtpPort,
                smtpEncryption: smtpEncModel,
                smtpUsername: smtpUser,
                smtpPassword: smtpPassword.isEmpty ? nil : smtpPassword,
                authMethod: authModel,
                oauthToken: nil,
                connectionTimeoutSec: safeTimeoutSeconds,
                enableLogging: connectionLogging,
                checkIntervalMin: intervalActive ? safeCheckInterval : nil,
                checkIntervalEnabled: intervalActive,
                folders: .init(
                    inbox: folderInbox.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "INBOX" : folderInbox.trimmingCharacters(in: .whitespacesAndNewlines),
                    sent: folderSent.trimmingCharacters(in: .whitespacesAndNewlines),
                    drafts: folderDrafts.trimmingCharacters(in: .whitespacesAndNewlines),
                    trash: folderTrash.trimmingCharacters(in: .whitespacesAndNewlines),
                    spam: folderSpam.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )

            print("🔧 DEBUG: MailAccountConfig created successfully")

            if let idx = list.firstIndex(where: { $0.id == id }) {
                list[idx] = cfg
                print("🔧 DEBUG: Updated existing account at index \(idx)")
            } else {
                list.append(cfg)
                print("🔧 DEBUG: Added new account to list")
            }
            
            print("🔧 DEBUG: Saving account list to UserDefaults...")
            DispatchQueue.main.async {
                MailStorageEditorHelper.save(list)
                print("🔧 DEBUG: Account list saved successfully")
            }

            // Also persist special folders into DAO to keep the replica in sync
            let folderMap: [String: String] = [
                "inbox": folderInbox.isEmpty ? "INBOX" : folderInbox,
                "sent": folderSent,
                "drafts": folderDrafts,
                "trash": folderTrash,
                "spam": folderSpam
            ]
            
            print("🔧 DEBUG: Starting async DAO operation...")
            
            // Asynchronous DAO operation with delayed UI updates to prevent crashes
            Task.detached { [id, folderMap] in
                print("🔧 DEBUG: Task started for DAO operations")
                var saveSuccessful = false
                
                // Add timeout protection
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second timeout
                        print("⚠️ DEBUG: DAO operation timeout - proceeding without DAO save")
                    } catch {
                        print("⚠️ DEBUG: Timeout task was cancelled: \(error)")
                    }
                }
                
                let daoTask = Task {
                    await MainActor.run {
                        if let factory = MailRepository.shared.factory {
                            do {
                                print("🔧 DEBUG: Starting DAO save operation...")
                                try factory.mailReadDAO.saveSpecialFolders(accountId: id, map: folderMap)
                                print("✅ Special folders saved to DAO successfully")
                                saveSuccessful = true
                            } catch {
                                print("⚠️ Failed to save special folders to DAO: \(error)")
                                // Continue anyway, the UserDefaults save succeeded
                                saveSuccessful = true // UserDefaults save was successful
                            }
                        } else {
                            print("🔧 DEBUG: No DAO factory available")
                            saveSuccessful = true // No DAO available, but UserDefaults save succeeded
                        }
                    }
                }
                
                // Race between DAO operation and timeout
                _ = await withTaskGroup(of: Void.self) { group in
                    group.addTask { 
                        do {
                            await daoTask.value 
                        } catch {
                            print("⚠️ DEBUG: DAO task failed: \(error)")
                        }
                    }
                    group.addTask { 
                        do {
                            await timeoutTask.value
                        } catch {
                            print("⚠️ DEBUG: Timeout task failed: \(error)")
                        }
                    }
                    
                    // Wait for first to complete
                    do {
                        await group.next()
                    } catch {
                        print("⚠️ DEBUG: TaskGroup failed: \(error)")
                    }
                    group.cancelAll() // Cancel the other task
                }
                
                if !saveSuccessful {
                    saveSuccessful = true // Proceed anyway after timeout
                    print("🔧 DEBUG: Proceeding without DAO save due to timeout")
                }
                
                // Only proceed with notification and dismiss if save was successful
                if saveSuccessful {
                    print("🔧 DEBUG: Scheduling UI updates...")
                    // Longer delay to ensure all operations complete
                    await MainActor.run {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            print("🔧 DEBUG: Posting notification...")
                            NotificationCenter.default.post(name: .mailAccountsDidChange, object: nil)
                            
                            // Additional delay before dismiss to prevent crash
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                print("🔧 DEBUG: Dismissing editor...")
                                self.dismiss()
                            }
                        }
                    }
                }
            }
            
        } catch {
            print("❌ ERROR in saveAccount(): \(error)")
            print("❌ ERROR details: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers
    /// Decide intelligently whether the DAO value should override the UserDefaults value
    private func preferDaoValue(_ daoValue: String?, over userDefaultsValue: String, default defaultValue: String) -> String {
        // If DAO is nil or empty, keep UserDefaults
        guard let daoValue = daoValue, !daoValue.isEmpty else { return userDefaultsValue }
        // If DAO equals the default and UserDefaults has a value, prefer UserDefaults (likely user-configured)
        if daoValue == defaultValue && !userDefaultsValue.isEmpty {
            return userDefaultsValue
        }
        // If DAO differs from default, it's likely real server data
        if daoValue != defaultValue {
            return daoValue
        }
        // If UserDefaults is empty, use DAO even if it's default (better than nothing)
        if userDefaultsValue.isEmpty {
            return daoValue
        }
        // Fallback to DAO value
        return daoValue
    }

    private func updateDefaultIncomingPort() {
        switch (recvProtocol, recvEnc) {
        case (.imap, .sslTLS): recvPort = 993
        case (.imap, .startTLS): recvPort = 143
        case (.imap, .none): recvPort = 143
        case (.pop3, .sslTLS): recvPort = 995
        case (.pop3, .startTLS): recvPort = 110
        case (.pop3, .none): recvPort = 110
        }
    }

    private func updateDefaultSmtpPort() {
        switch smtpEnc {
        case .sslTLS: smtpPort = 465
        case .startTLS: smtpPort = 587
        case .none: smtpPort = 25
        }
    }

    private func fetchFolders() async {
        await MainActor.run {
            isFetchingFolders = true
        }
        
        guard recvProtocol == .imap else {
            await MainActor.run {
                isFetchingFolders = false
                testMessage = String(localized: "mail.editor.fetch.onlyImap")
                showTestAlert = true
            }
            return
        }
        // Minimal input validation
        guard !recvHost.isEmpty, recvPort > 0, !recvUser.isEmpty else {
            await MainActor.run {
                isFetchingFolders = false
                testMessage = String(localized: "mail.editor.fetch.missingCredentials")
                showTestAlert = true
            }
            return
        }
        let login = FolderDiscoveryService.IMAPLogin(
            host: recvHost,
            port: recvPort,
            useTLS: (recvEnc == .sslTLS),
            sniHost: recvHost,
            username: recvUser,
            password: recvPassword, // uses in-memory value
            connectionTimeoutSec: timeoutSeconds,
            commandTimeoutSec: max(5, timeoutSeconds/2),
            idleTimeoutSec: max(10, timeoutSeconds)
        )
        let accId = existingId ?? UUID()
        let result = await FolderDiscoveryService.shared.discover(accountId: accId, login: login)
        switch result {
        case .success(let map):
            await MainActor.run {
                // Trim alle Folder-Namen nach Discovery
                folderInbox  = map.inbox.trimmingCharacters(in: .whitespacesAndNewlines)
                folderSent   = map.sent.trimmingCharacters(in: .whitespacesAndNewlines)
                folderDrafts = map.drafts.trimmingCharacters(in: .whitespacesAndNewlines)
                folderTrash  = map.trash.trimmingCharacters(in: .whitespacesAndNewlines)
                folderSpam   = map.spam.trimmingCharacters(in: .whitespacesAndNewlines)
                
                print("✅ Discovered folders (trimmed):")
                print("  - Inbox: '\(folderInbox)'")
                print("  - Sent: '\(folderSent)'")
                print("  - Drafts: '\(folderDrafts)'")
                print("  - Trash: '\(folderTrash)'")
                print("  - Spam: '\(folderSpam)'")
                
                // More informative feedback for the user
                let details = [
                    "INBOX: \(folderInbox)",
                    "Sent: \(folderSent)",
                    "Drafts: \(folderDrafts)",
                    "Trash: \(folderTrash)",
                    "Spam: \(folderSpam)"
                ].joined(separator: "\n")
                testMessage = String(localized: "mail.editor.fetch.success") + "\n" + details
                
                // Delay showing alert to prevent immediate crash
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isFetchingFolders = false
                    showTestAlert = true
                }
            }
            if let id = existingId {
                var list = MailStorageEditorHelper.load()
                if let idx = list.firstIndex(where: { $0.id == id }) {
                    var cfg = list[idx]
                    cfg.folders = .init(
                        inbox: map.inbox.trimmingCharacters(in: .whitespacesAndNewlines),
                        sent: map.sent.trimmingCharacters(in: .whitespacesAndNewlines),
                        drafts: map.drafts.trimmingCharacters(in: .whitespacesAndNewlines),
                        trash: map.trash.trimmingCharacters(in: .whitespacesAndNewlines),
                        spam: map.spam.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    list[idx] = cfg
                    MailStorageEditorHelper.save(list)
                    
                    // Keep DAO replica in sync - convert FolderMap to Dictionary
                    let daoMap: [String: String] = [
                        "inbox": map.inbox.trimmingCharacters(in: .whitespacesAndNewlines),
                        "sent": map.sent.trimmingCharacters(in: .whitespacesAndNewlines),
                        "drafts": map.drafts.trimmingCharacters(in: .whitespacesAndNewlines),
                        "trash": map.trash.trimmingCharacters(in: .whitespacesAndNewlines),
                        "spam": map.spam.trimmingCharacters(in: .whitespacesAndNewlines)
                    ]
                    
                    // Asynchronous DAO operation to avoid blocking UI  
                    Task {
                        var daoSaveSuccessful = false
                        
                        if let factory = MailRepository.shared.factory {
                            do {
                                try factory.mailReadDAO.saveSpecialFolders(accountId: id, map: daoMap)
                                print("✅ Discovered folders saved to DAO successfully")
                                daoSaveSuccessful = true
                            } catch {
                                print("⚠️ Failed to save discovered folders to DAO: \(error)")
                                daoSaveSuccessful = true // Continue anyway, UserDefaults save succeeded
                            }
                        } else {
                            daoSaveSuccessful = true // No DAO available
                        }
                        
                        if daoSaveSuccessful {
                            // Delay notification to prevent crash
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                NotificationCenter.default.post(name: .mailAccountsDidChange, object: nil)
                            }
                        }
                    }
                }
            }
        case .failure(let err):
            await MainActor.run {
                testMessage = err.localizedDescription
                
                // Delay showing alert to prevent immediate crash
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    isFetchingFolders = false
                    showTestAlert = true
                }
            }
        }
    }
}

private extension String {
    func maskedEmail() -> String {
        guard let at = self.firstIndex(of: "@") else { return self }
        let name = self[..<at]
        let domain = self[self.index(after: at)...]
        let masked = name.prefix(1) + String(repeating: "â€¢", count: max(0, name.count - 2)) + name.suffix(1)
        return masked + "@" + domain
    }
}

