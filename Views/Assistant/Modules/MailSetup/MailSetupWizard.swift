// Views/Assistant/Modules/MailSetup/MailSetupWizard.swift
// AILO - Mail Setup Wizard Container

import SwiftUI
import Combine

// MARK: - Wizard State

@MainActor
final class MailSetupState: ObservableObject {
    // Step 1: E-Mail
    @Published var email: String = ""
    @Published var detectedProvider: EmailProviderPreset?

    // Step 2: Credentials
    @Published var password: String = ""
    @Published var displayName: String = ""
    @Published var useCustomSettings: Bool = false

    // Custom Settings (wenn Provider nicht erkannt)
    @Published var imapHost: String = ""
    @Published var imapPort: Int = 993
    @Published var imapEncryption: EmailProviderPreset.EncryptionType = .ssl
    @Published var smtpHost: String = ""
    @Published var smtpPort: Int = 587
    @Published var smtpEncryption: EmailProviderPreset.EncryptionType = .starttls

    // Step 3: Connection Test
    @Published var isTestingConnection: Bool = false
    @Published var connectionTestResult: ConnectionTestResult?
    @Published var imapTestPassed: Bool = false
    @Published var smtpTestPassed: Bool = false

    // Step 4: Folders
    @Published var discoveredFolders: [String] = []
    @Published var folderInbox: String = "INBOX"
    @Published var folderSent: String = ""
    @Published var folderDrafts: String = ""
    @Published var folderTrash: String = ""
    @Published var folderSpam: String = ""

    // Navigation
    @Published var currentStep: Int = 0
    @Published var isComplete: Bool = false
    @Published var errorMessage: String?
    @Published var isSaving: Bool = false

    // Generierte Account-ID für Discovery
    let accountId: UUID = UUID()

    enum ConnectionTestResult: Equatable {
        case success
        case failure(String)

        static func == (lhs: ConnectionTestResult, rhs: ConnectionTestResult) -> Bool {
            switch (lhs, rhs) {
            case (.success, .success): return true
            case (.failure(let a), .failure(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - Computed Properties

    var canProceedFromStep1: Bool {
        isValidEmail(email)
    }

    var canProceedFromStep2: Bool {
        !password.isEmpty && (detectedProvider != nil || hasValidCustomSettings)
    }

    var hasValidCustomSettings: Bool {
        !imapHost.isEmpty && imapPort > 0 && !smtpHost.isEmpty && smtpPort > 0
    }

    var effectiveImapHost: String {
        useCustomSettings ? imapHost : (detectedProvider?.imapHost ?? imapHost)
    }

    var effectiveImapPort: Int {
        useCustomSettings ? imapPort : (detectedProvider?.imapPort ?? imapPort)
    }

    var effectiveImapEncryption: MailEncryption {
        let enc = useCustomSettings ? imapEncryption : (detectedProvider?.imapEncryption ?? imapEncryption)
        switch enc {
        case .ssl: return .sslTLS
        case .starttls: return .startTLS
        case .none: return .none
        }
    }

    var effectiveSmtpHost: String {
        useCustomSettings ? smtpHost : (detectedProvider?.smtpHost ?? smtpHost)
    }

    var effectiveSmtpPort: Int {
        useCustomSettings ? smtpPort : (detectedProvider?.smtpPort ?? smtpPort)
    }

    var effectiveSmtpEncryption: MailEncryption {
        let enc = useCustomSettings ? smtpEncryption : (detectedProvider?.smtpEncryption ?? smtpEncryption)
        switch enc {
        case .ssl: return .sslTLS
        case .starttls: return .startTLS
        case .none: return .none
        }
    }

    // MARK: - Build MailAccountConfig

    func buildMailAccountConfig() -> MailAccountConfig {
        MailAccountConfig(
            id: accountId,
            accountName: detectedProvider?.name ?? effectiveImapHost,
            displayName: displayName.isEmpty ? nil : displayName,
            emailAddress: email,
            replyTo: nil,
            signingEnabled: false,
            signingCertificateId: nil,
            recvProtocol: .imap,
            recvHost: effectiveImapHost,
            recvPort: effectiveImapPort,
            recvEncryption: effectiveImapEncryption,
            recvUsername: email,
            recvPassword: password,
            smtpHost: effectiveSmtpHost,
            smtpPort: effectiveSmtpPort,
            smtpEncryption: effectiveSmtpEncryption,
            smtpUsername: email,
            smtpPassword: password,
            authMethod: detectedProvider?.requiresAppPassword == true ? .appPassword : .password,
            oauthToken: nil,
            connectionTimeoutSec: 15,
            enableLogging: false,
            autoMarkAsRead: true,
            checkIntervalMin: 5,
            checkIntervalEnabled: true,
            folders: .init(
                inbox: folderInbox,
                sent: folderSent,
                drafts: folderDrafts,
                trash: folderTrash,
                spam: folderSpam
            )
        )
    }

    // MARK: - Methods

    func detectProvider() {
        detectedProvider = EmailProviderDatabase.detect(email: email)

        // Auto-fill display name from email
        if displayName.isEmpty, let name = email.split(separator: "@").first {
            displayName = String(name).capitalized
        }

        // Pre-fill custom settings from detected provider
        if let provider = detectedProvider {
            imapHost = provider.imapHost
            imapPort = provider.imapPort
            imapEncryption = provider.imapEncryption
            smtpHost = provider.smtpHost
            smtpPort = provider.smtpPort
            smtpEncryption = provider.smtpEncryption
        }
    }

    func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }

    func reset() {
        email = ""
        password = ""
        displayName = ""
        detectedProvider = nil
        useCustomSettings = false
        imapHost = ""
        imapPort = 993
        smtpHost = ""
        smtpPort = 587
        connectionTestResult = nil
        imapTestPassed = false
        smtpTestPassed = false
        discoveredFolders = []
        folderInbox = "INBOX"
        folderSent = ""
        folderDrafts = ""
        folderTrash = ""
        folderSpam = ""
        currentStep = 0
        isComplete = false
        errorMessage = nil
        isSaving = false
    }
}

// MARK: - Mail Setup Wizard View

struct MailSetupWizard: View {
    @StateObject private var state = MailSetupState()
    @Environment(\.dismiss) private var dismiss

    // Completion Dialog
    @State private var showCompletionAlert: Bool = false
    @State private var savedAccountEmail: String = ""

    private let steps = [
        WizardStepInfo(title: "wizard.step.email", icon: "envelope"),
        WizardStepInfo(title: "wizard.step.credentials", icon: "key"),
        WizardStepInfo(title: "wizard.step.test", icon: "checkmark.circle"),
        WizardStepInfo(title: "wizard.step.folders", icon: "folder")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Progress Bar
            WizardProgressBar(
                steps: steps,
                currentStep: state.currentStep
            )
            .padding()

            // Content
            TabView(selection: $state.currentStep) {
                StepEmailInput()
                    .environmentObject(state)
                    .tag(0)

                StepCredentials()
                    .environmentObject(state)
                    .tag(1)

                StepConnectionTest()
                    .environmentObject(state)
                    .tag(2)

                StepFolders()
                    .environmentObject(state)
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: state.currentStep)

            // Navigation Buttons
            WizardNavigationButtons(
                currentStep: $state.currentStep,
                totalSteps: steps.count,
                canProceed: canProceedFromCurrentStep,
                isLastStep: state.currentStep == steps.count - 1,
                onNext: handleNext,
                onBack: handleBack,
                onFinish: handleFinish
            )
            .padding()
        }
        .navigationTitle(Text("wizard.mail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("common.cancel") {
                    dismiss()
                }
            }
        }
        .alert("common.error", isPresented: .constant(state.errorMessage != nil)) {
            Button("common.ok") {
                state.errorMessage = nil
            }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .alert("wizard.complete.title", isPresented: $showCompletionAlert) {
            Button("wizard.complete.another") {
                // Reset wizard for another account
                state.reset()
            }
            Button("wizard.complete.done") {
                dismiss()
            }
        } message: {
            Text("wizard.complete.message \(savedAccountEmail)")
        }
    }

    // MARK: - Navigation Logic

    private var canProceedFromCurrentStep: Bool {
        switch state.currentStep {
        case 0: return state.canProceedFromStep1
        case 1: return state.canProceedFromStep2
        case 2: return state.connectionTestResult == .success
        case 3: return true
        default: return false
        }
    }

    private func handleNext() {
        switch state.currentStep {
        case 0:
            state.detectProvider()
            state.currentStep = 1
        case 1:
            state.currentStep = 2
        case 2:
            state.currentStep = 3
        default:
            break
        }
    }

    private func handleBack() {
        if state.currentStep > 0 {
            state.currentStep -= 1
        }
    }

    private func handleFinish() {
        Task {
            await saveAccount()
        }
    }

    private func saveAccount() async {
        state.isSaving = true

        // MailAccountConfig erstellen
        let config = state.buildMailAccountConfig()

        // In UserDefaults speichern (wie MailEditor)
        var accounts = MailStorageHelper.load()

        // Prüfen ob Account mit gleicher E-Mail bereits existiert
        if let existingIndex = accounts.firstIndex(where: { $0.emailAddress == config.emailAddress }) {
            accounts[existingIndex] = config
            print("🔄 Updated existing account: \(config.emailAddress)")
        } else {
            accounts.append(config)
            print("✅ Added new account: \(config.emailAddress)")
        }

        MailStorageHelper.save(accounts)

        // Account automatisch aktivieren
        MailStorageHelper.activateAccount(config.id)
        print("✅ Account activated: \(config.emailAddress)")

        // Benachrichtigung senden
        NotificationCenter.default.post(name: .mailAccountsDidChange, object: nil)

        state.isSaving = false
        state.isComplete = true

        // Show completion dialog
        savedAccountEmail = config.emailAddress
        showCompletionAlert = true
    }
}

// MARK: - Step Info

struct WizardStepInfo: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let icon: String
}

// MARK: - Storage Helper

fileprivate enum MailStorageHelper {
    static let key = "mail.accounts"
    static let activeKey = "mail.accounts.active"

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

    static func activateAccount(_ accountId: UUID) {
        var activeIDs: [UUID] = []
        if let data = UserDefaults.standard.data(forKey: activeKey),
           let arr = try? JSONDecoder().decode([UUID].self, from: data) {
            activeIDs = arr
        }

        if !activeIDs.contains(accountId) {
            activeIDs.append(accountId)
            if let data = try? JSONEncoder().encode(activeIDs) {
                UserDefaults.standard.set(data, forKey: activeKey)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MailSetupWizard()
    }
}
