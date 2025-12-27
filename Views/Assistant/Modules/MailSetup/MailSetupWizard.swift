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

    enum ConnectionTestResult: Equatable {
        case success
        case failure(String)
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
        detectedProvider?.imapHost ?? imapHost
    }

    var effectiveImapPort: Int {
        detectedProvider?.imapPort ?? imapPort
    }

    var effectiveSmtpHost: String {
        detectedProvider?.smtpHost ?? smtpHost
    }

    var effectiveSmtpPort: Int {
        detectedProvider?.smtpPort ?? smtpPort
    }

    // MARK: - Methods

    func detectProvider() {
        detectedProvider = EmailProviderDatabase.detect(email: email)

        // Auto-fill display name from email
        if displayName.isEmpty, let name = email.split(separator: "@").first {
            displayName = String(name).capitalized
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
        discoveredFolders = []
        currentStep = 0
        isComplete = false
        errorMessage = nil
    }
}

// MARK: - Mail Setup Wizard View

struct MailSetupWizard: View {
    @StateObject private var state = MailSetupState()
    @Environment(\.dismiss) private var dismiss

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
        // TODO: Account über DAO speichern
        // Hier die MailAccountConfig erstellen und persistieren

        state.isComplete = true
        dismiss()
    }
}

// MARK: - Step Info

struct WizardStepInfo: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let icon: String
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MailSetupWizard()
    }
}
