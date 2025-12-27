// Views/Assistant/Modules/AISetup/AISetupSteps/AIStepConnection.swift
// AILO - Wizard Step 2: Verbindungsdaten eingeben

import SwiftUI

struct AIStepConnection: View {
    @EnvironmentObject var state: AISetupState
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case displayName, baseURL, port, apiKey
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 48))
                        .foregroundStyle(.purple.gradient)

                    Text("wizard.ai.connection.title")
                        .font(.title2.bold())

                    Text("wizard.ai.connection.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Provider Badge
                HStack(spacing: 10) {
                    Image(systemName: iconForType)
                        .foregroundStyle(.purple)
                    Text(state.selectedType.rawValue)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.1))
                .clipShape(Capsule())

                // Form Fields
                VStack(spacing: 16) {
                    // Display Name
                    AIFormField(
                        label: "wizard.ai.connection.displayName",
                        icon: "textformat"
                    ) {
                        TextField("", text: $state.displayName, prompt: Text(state.selectedType.rawValue))
                            .focused($focusedField, equals: .displayName)
                    }

                    // Base URL
                    AIFormField(
                        label: "wizard.ai.connection.baseURL",
                        icon: "globe"
                    ) {
                        TextField("", text: $state.baseURL, prompt: Text(state.selectedType.defaultBaseURL))
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .baseURL)
                    }

                    // Port
                    AIFormField(
                        label: "wizard.ai.connection.port",
                        icon: "number"
                    ) {
                        TextField("", text: $state.port, prompt: Text(state.selectedType.defaultPort))
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                    }

                    // API Key (wenn erforderlich)
                    if state.selectedType.requiresAPIKey {
                        AIFormField(
                            label: "wizard.ai.connection.apiKey",
                            icon: "key",
                            isRequired: true
                        ) {
                            SecureField("", text: $state.apiKey, prompt: Text(apiKeyPlaceholder))
                                .textContentType(.password)
                                .focused($focusedField, equals: .apiKey)
                        }

                        // API Key Link
                        if let url = apiKeyURL {
                            Link(destination: url) {
                                HStack {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("wizard.ai.connection.getApiKey")
                                }
                                .font(.subheadline)
                            }
                            .padding(.horizontal)
                        }
                    } else {
                        // Kein API-Key erforderlich
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("wizard.ai.connection.noKeyNeeded")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                    }

                    // Anthropic-spezifischer Hinweis
                    if state.selectedType == .anthropic {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text("wizard.ai.connection.anthropicHint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            // Setze Defaults wenn noch nicht gesetzt
            if state.baseURL.isEmpty {
                state.baseURL = state.selectedType.defaultBaseURL
            }
            if state.port.isEmpty {
                state.port = state.selectedType.defaultPort
            }
        }
    }

    // MARK: - Computed Properties

    private var iconForType: String {
        switch state.selectedType {
        case .openAI: return "brain.head.profile"
        case .mistral: return "wind"
        case .anthropic: return "sparkles"
        case .ollama: return "desktopcomputer"
        case .custom: return "slider.horizontal.3"
        }
    }

    private var apiKeyPlaceholder: String {
        switch state.selectedType {
        case .openAI: return "sk-..."
        case .mistral: return "..."
        case .anthropic: return "sk-ant-..."
        case .custom: return "..."
        default: return ""
        }
    }

    private var apiKeyURL: URL? {
        switch state.selectedType {
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .mistral: return URL(string: "https://console.mistral.ai/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        default: return nil
        }
    }
}

// MARK: - Form Field

private struct AIFormField<Content: View>: View {
    let label: LocalizedStringKey
    let icon: String
    var isRequired: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if isRequired {
                    Text("*")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

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

// MARK: - Preview

#Preview {
    NavigationStack {
        AIStepConnection()
            .environmentObject({
                let state = AISetupState()
                state.selectedType = .openAI
                return state
            }())
    }
}
