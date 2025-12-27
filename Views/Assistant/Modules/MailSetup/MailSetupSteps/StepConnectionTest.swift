// Views/Assistant/Modules/MailSetup/MailSetupSteps/StepConnectionTest.swift
// AILO - Wizard Step 3: Connection Test (Produktive Implementierung)

import SwiftUI

struct StepConnectionTest: View {
    @EnvironmentObject var state: MailSetupState

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(statusColor.opacity(0.15))
                            .frame(width: 100, height: 100)

                        if state.isTestingConnection {
                            ProgressView()
                                .scaleEffect(1.5)
                        } else {
                            Image(systemName: statusIcon)
                                .font(.system(size: 44))
                                .foregroundStyle(statusColor)
                        }
                    }

                    Text(statusTitle)
                        .font(.title2.bold())

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Connection Details
                VStack(spacing: 16) {
                    ConnectionDetailRow(
                        icon: "envelope",
                        label: "wizard.test.email",
                        value: state.email,
                        status: nil
                    )

                    ConnectionDetailRow(
                        icon: "arrow.down.circle",
                        label: "wizard.test.imap",
                        value: "\(state.effectiveImapHost):\(state.effectiveImapPort)",
                        status: state.isTestingConnection ? .testing : (state.imapTestPassed ? .success : (state.connectionTestResult != nil ? .failure : nil))
                    )

                    ConnectionDetailRow(
                        icon: "arrow.up.circle",
                        label: "wizard.test.smtp",
                        value: "\(state.effectiveSmtpHost):\(state.effectiveSmtpPort)",
                        status: state.isTestingConnection ? .testing : (state.smtpTestPassed ? .success : (state.connectionTestResult != nil ? .failure : nil))
                    )
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                // Error Message
                if case .failure(let message) = state.connectionTestResult {
                    ErrorMessageView(message: message)
                        .padding(.horizontal)
                }

                // Test Button
                Button {
                    Task {
                        await runConnectionTest()
                    }
                } label: {
                    HStack {
                        if state.isTestingConnection {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: state.connectionTestResult == nil ? "play.fill" : "arrow.clockwise")
                        }
                        Text(state.connectionTestResult == nil ? "wizard.test.start" : "wizard.test.retry")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(state.isTestingConnection ? Color.gray : Color.teal)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(state.isTestingConnection)
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            // Auto-start test on appear
            if state.connectionTestResult == nil {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await runConnectionTest()
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        if state.isTestingConnection { return .blue }
        switch state.connectionTestResult {
        case .success: return .green
        case .failure: return .red
        case nil: return .gray
        }
    }

    private var statusIcon: String {
        switch state.connectionTestResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case nil: return "antenna.radiowaves.left.and.right"
        }
    }

    private var statusTitle: LocalizedStringKey {
        if state.isTestingConnection { return "wizard.test.testing" }
        switch state.connectionTestResult {
        case .success: return "wizard.test.success"
        case .failure: return "wizard.test.failed"
        case nil: return "wizard.test.ready"
        }
    }

    private var statusSubtitle: LocalizedStringKey {
        if state.isTestingConnection { return "wizard.test.testingSubtitle" }
        switch state.connectionTestResult {
        case .success: return "wizard.test.successSubtitle"
        case .failure: return "wizard.test.failedSubtitle"
        case nil: return "wizard.test.readySubtitle"
        }
    }

    // MARK: - Connection Test (PRODUKTIV)

    private func runConnectionTest() async {
        state.isTestingConnection = true
        state.connectionTestResult = nil
        state.imapTestPassed = false
        state.smtpTestPassed = false

        // MailAccountConfig aus State bauen
        let config = state.buildMailAccountConfig()

        print("🔌 [Wizard] Starting connection test...")
        print("🔌 [Wizard] IMAP: \(config.recvHost):\(config.recvPort)")
        print("🔌 [Wizard] SMTP: \(config.smtpHost):\(config.smtpPort)")

        // MailSendReceive für echten Test nutzen
        let service = MailSendReceive()
        let result = await service.testConnection(cfg: config)

        switch result {
        case .success:
            print("✅ [Wizard] Connection test successful!")
            state.imapTestPassed = true
            state.smtpTestPassed = true
            state.connectionTestResult = .success

            // Nach erfolgreichem Test: Ordner discovern
            await discoverFolders(config: config)

        case .failure(let error):
            print("❌ [Wizard] Connection test failed: \(error.localizedDescription)")
            state.connectionTestResult = .failure(error.localizedDescription)
        }

        state.isTestingConnection = false
    }

    // MARK: - Folder Discovery (PRODUKTIV)

    private func discoverFolders(config: MailAccountConfig) async {
        print("📁 [Wizard] Starting folder discovery...")

        // FolderDiscoveryService nutzen
        let login = FolderDiscoveryService.IMAPLogin(
            host: config.recvHost,
            port: config.recvPort,
            useTLS: config.recvEncryption == .sslTLS,
            sniHost: config.recvHost,
            username: config.recvUsername,
            password: config.recvPassword ?? "",
            connectionTimeoutSec: config.connectionTimeoutSec,
            commandTimeoutSec: max(5, config.connectionTimeoutSec / 2),
            idleTimeoutSec: 10
        )

        // Detaillierte Ordnerliste abrufen
        let listResult = await FolderDiscoveryService.shared.listFoldersDetailed(
            accountId: state.accountId,
            login: login
        )

        switch listResult {
        case .success(let folders):
            print("✅ [Wizard] Discovered \(folders.count) folders")
            state.discoveredFolders = folders.map { $0.name }

            // Special-Use Discovery für automatische Zuordnung
            let discoveryResult = await FolderDiscoveryService.shared.discover(
                accountId: state.accountId,
                login: login
            )

            switch discoveryResult {
            case .success(let folderMap):
                print("✅ [Wizard] Auto-mapped folders: inbox=\(folderMap.inbox), sent=\(folderMap.sent)")
                state.folderInbox = folderMap.inbox
                state.folderSent = folderMap.sent
                state.folderDrafts = folderMap.drafts
                state.folderTrash = folderMap.trash
                state.folderSpam = folderMap.spam

            case .failure(let error):
                print("⚠️ [Wizard] Auto-mapping failed, using defaults: \(error)")
                applyDefaultFolderMapping()
            }

        case .failure(let error):
            print("⚠️ [Wizard] Folder list failed: \(error)")
            // Fallback: Bekannte Provider-Ordner
            applyProviderFolderDefaults()
        }
    }

    private func applyDefaultFolderMapping() {
        state.folderInbox = "INBOX"

        // Versuche bekannte Ordnernamen zu matchen
        // Sent
        if let sent = state.discoveredFolders.first(where: {
            ["sent", "sent items", "sent mail", "gesendet", "[gmail]/sent mail"].contains($0.lowercased())
        }) {
            state.folderSent = sent
        }

        // Drafts
        if let drafts = state.discoveredFolders.first(where: {
            ["drafts", "draft", "entwürfe", "[gmail]/drafts"].contains($0.lowercased())
        }) {
            state.folderDrafts = drafts
        }

        // Trash
        if let trash = state.discoveredFolders.first(where: {
            ["trash", "deleted", "deleted items", "papierkorb", "[gmail]/trash"].contains($0.lowercased())
        }) {
            state.folderTrash = trash
        }

        // Spam
        if let spam = state.discoveredFolders.first(where: {
            ["spam", "junk", "junk email", "[gmail]/spam"].contains($0.lowercased())
        }) {
            state.folderSpam = spam
        }
    }

    private func applyProviderFolderDefaults() {
        // Fallback basierend auf Provider
        if let provider = state.detectedProvider {
            switch provider.id {
            case "gmail":
                state.discoveredFolders = ["INBOX", "[Gmail]/Sent Mail", "[Gmail]/Drafts", "[Gmail]/Trash", "[Gmail]/Spam"]
                state.folderInbox = "INBOX"
                state.folderSent = "[Gmail]/Sent Mail"
                state.folderDrafts = "[Gmail]/Drafts"
                state.folderTrash = "[Gmail]/Trash"
                state.folderSpam = "[Gmail]/Spam"
            case "outlook":
                state.discoveredFolders = ["INBOX", "Sent Items", "Drafts", "Deleted Items", "Junk Email"]
                state.folderInbox = "INBOX"
                state.folderSent = "Sent Items"
                state.folderDrafts = "Drafts"
                state.folderTrash = "Deleted Items"
                state.folderSpam = "Junk Email"
            default:
                state.discoveredFolders = ["INBOX", "Sent", "Drafts", "Trash", "Spam"]
                state.folderInbox = "INBOX"
                state.folderSent = "Sent"
                state.folderDrafts = "Drafts"
                state.folderTrash = "Trash"
                state.folderSpam = "Spam"
            }
        } else {
            state.discoveredFolders = ["INBOX", "Sent", "Drafts", "Trash", "Spam"]
            applyDefaultFolderMapping()
        }
    }
}

// MARK: - Connection Status

enum ConnectionStatus {
    case testing, success, failure
}

// MARK: - Connection Detail Row

private struct ConnectionDetailRow: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    let status: ConnectionStatus?

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline)
            }

            Spacer()

            if let status = status {
                Group {
                    switch status {
                    case .testing:
                        ProgressView()
                            .scaleEffect(0.8)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

// MARK: - Error Message View

private struct ErrorMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.test.errorTitle")
                    .font(.subheadline.weight(.semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        StepConnectionTest()
            .environmentObject({
                let state = MailSetupState()
                state.email = "test@gmail.com"
                state.password = "test123"
                state.detectedProvider = EmailProviderDatabase.gmail
                return state
            }())
    }
}
