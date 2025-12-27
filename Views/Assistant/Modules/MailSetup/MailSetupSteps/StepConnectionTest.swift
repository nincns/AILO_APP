// Views/Assistant/Modules/MailSetup/MailSetupSteps/StepConnectionTest.swift
// AILO - Wizard Step 3: Connection Test

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
                        status: state.isTestingConnection ? .testing : testResultStatus
                    )

                    ConnectionDetailRow(
                        icon: "arrow.up.circle",
                        label: "wizard.test.smtp",
                        value: "\(state.effectiveSmtpHost):\(state.effectiveSmtpPort)",
                        status: state.isTestingConnection ? .testing : testResultStatus
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
                        Image(systemName: state.connectionTestResult == nil ? "play.fill" : "arrow.clockwise")
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

    private var testResultStatus: ConnectionStatus? {
        switch state.connectionTestResult {
        case .success: return .success
        case .failure: return .failure
        case nil: return nil
        }
    }

    // MARK: - Connection Test

    private func runConnectionTest() async {
        state.isTestingConnection = true
        state.connectionTestResult = nil

        // Simuliere Test (TODO: echten MailSendReceive.testConnection nutzen)
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // TODO: Echten Test durchführen
            // let service = MailSendReceive()
            // let config = buildMailAccountConfig()
            // let result = await service.testConnection(cfg: config)

            // Simulated success for now
            state.connectionTestResult = .success

            // Ordner laden nach erfolgreichem Test
            await discoverFolders()

        } catch {
            state.connectionTestResult = .failure(error.localizedDescription)
        }

        state.isTestingConnection = false
    }

    private func discoverFolders() async {
        // TODO: FolderDiscoveryService nutzen
        // Simulierte Ordnerliste
        state.discoveredFolders = ["INBOX", "Sent", "Drafts", "Trash", "Spam", "Archive"]

        // Auto-assign bekannte Ordner
        state.folderInbox = "INBOX"
        if state.discoveredFolders.contains("Sent") { state.folderSent = "Sent" }
        if state.discoveredFolders.contains("Drafts") { state.folderDrafts = "Drafts" }
        if state.discoveredFolders.contains("Trash") { state.folderTrash = "Trash" }
        if state.discoveredFolders.contains("Spam") { state.folderSpam = "Spam" }
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
                state.detectedProvider = EmailProviderDatabase.gmail
                return state
            }())
    }
}
