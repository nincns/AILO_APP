// Views/Assistant/Modules/MailSetup/MailSetupSteps/StepCredentials.swift
// AILO - Wizard Step 2: Credentials & Server Settings

import SwiftUI

struct StepCredentials: View {
    @EnvironmentObject var state: MailSetupState
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case displayName, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.teal.gradient)

                    Text("wizard.credentials.title")
                        .font(.title2.bold())

                    Text("wizard.credentials.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Provider Info (wenn erkannt)
                if let provider = state.detectedProvider {
                    ProviderInfoBanner(provider: provider)
                        .padding(.horizontal)
                }

                // Credentials Form
                VStack(spacing: 16) {
                    // Display Name
                    FormField(
                        label: "wizard.credentials.displayName",
                        icon: "person",
                        placeholder: "Max Mustermann"
                    ) {
                        TextField("", text: $state.displayName)
                            .textContentType(.name)
                            .focused($focusedField, equals: .displayName)
                    }

                    // Password
                    FormField(
                        label: state.detectedProvider?.requiresAppPassword == true
                            ? "wizard.credentials.appPassword"
                            : "wizard.credentials.password",
                        icon: "lock",
                        placeholder: "••••••••"
                    ) {
                        SecureField("", text: $state.password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                    }

                    // App-Password Hinweis
                    if let provider = state.detectedProvider, provider.requiresAppPassword {
                        AppPasswordHint(provider: provider)
                    }
                }
                .padding(.horizontal)

                // Manual Settings Toggle
                if state.detectedProvider == nil {
                    ManualServerSettings()
                        .environmentObject(state)
                        .padding(.horizontal)
                } else {
                    // Option für manuelle Einstellungen
                    DisclosureGroup(isExpanded: $state.useCustomSettings) {
                        ManualServerSettings()
                            .environmentObject(state)
                            .padding(.top, 8)
                    } label: {
                        Label("wizard.credentials.advancedSettings", systemImage: "gearshape")
                            .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            focusedField = .displayName
        }
    }
}

// MARK: - Form Field

private struct FormField<Content: View>: View {
    let label: LocalizedStringKey
    let icon: String
    let placeholder: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                content()
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Provider Info Banner

private struct ProviderInfoBanner: View {
    let provider: EmailProviderPreset

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.icon)
                .font(.title3)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))

                Text("IMAP: \(provider.imapHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - App Password Hint

private struct AppPasswordHint: View {
    let provider: EmailProviderPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)

                Text("wizard.credentials.appPasswordRequired")
                    .font(.subheadline.weight(.medium))
            }

            if let note = provider.setupNotes {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let url = provider.appPasswordURL, let link = URL(string: url) {
                Link(destination: link) {
                    HStack {
                        Text("wizard.credentials.createAppPassword")
                            .font(.subheadline)

                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Manual Server Settings

private struct ManualServerSettings: View {
    @EnvironmentObject var state: MailSetupState

    var body: some View {
        VStack(spacing: 16) {
            // IMAP Settings
            GroupBox(label: Label("IMAP", systemImage: "arrow.down.circle")) {
                VStack(spacing: 12) {
                    HStack {
                        TextField("imap.example.com", text: $state.imapHost)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("993", value: $state.imapPort, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                    }

                    Picker("wizard.credentials.encryption", selection: $state.imapEncryption) {
                        ForEach(EmailProviderPreset.EncryptionType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 8)
            }

            // SMTP Settings
            GroupBox(label: Label("SMTP", systemImage: "arrow.up.circle")) {
                VStack(spacing: 12) {
                    HStack {
                        TextField("smtp.example.com", text: $state.smtpHost)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)

                        TextField("587", value: $state.smtpPort, format: .number)
                            .keyboardType(.numberPad)
                            .frame(width: 70)
                    }

                    Picker("wizard.credentials.encryption", selection: $state.smtpEncryption) {
                        ForEach(EmailProviderPreset.EncryptionType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        StepCredentials()
            .environmentObject({
                let state = MailSetupState()
                state.email = "test@gmail.com"
                state.detectedProvider = EmailProviderDatabase.gmail
                return state
            }())
    }
}
