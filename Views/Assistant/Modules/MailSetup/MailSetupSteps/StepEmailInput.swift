// Views/Assistant/Modules/MailSetup/MailSetupSteps/StepEmailInput.swift
// AILO - Wizard Step 1: E-Mail Eingabe

import SwiftUI

struct StepEmailInput: View {
    @EnvironmentObject var state: MailSetupState
    @FocusState private var isEmailFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge.person.crop")
                        .font(.system(size: 56))
                        .foregroundStyle(.teal.gradient)

                    Text("wizard.email.title")
                        .font(.title2.bold())

                    Text("wizard.email.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Email Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("wizard.email.label")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: "envelope")
                            .foregroundStyle(.secondary)

                        TextField("beispiel@email.de", text: $state.email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isEmailFocused)
                            .onChange(of: state.email) { _, newValue in
                                // Live Provider-Erkennung
                                if state.isValidEmail(newValue) {
                                    state.detectProvider()
                                } else {
                                    state.detectedProvider = nil
                                }
                            }

                        // Validation Icon
                        if !state.email.isEmpty {
                            Image(systemName: state.isValidEmail(state.email) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(state.isValidEmail(state.email) ? .green : .red)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Provider Detection Result
                if let provider = state.detectedProvider {
                    ProviderDetectedCard(provider: provider)
                        .padding(.horizontal)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // Quick Select Buttons
                VStack(alignment: .leading, spacing: 12) {
                    Text("wizard.email.quickSelect")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 12) {
                        ForEach(EmailProviderDatabase.allProviders.prefix(6)) { provider in
                            ProviderQuickButton(provider: provider) {
                                // Nur Domain einfügen wenn E-Mail leer
                                if state.email.isEmpty {
                                    state.email = "@\(provider.domains.first ?? "")"
                                    isEmailFocused = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isEmailFocused = true
            }
        }
    }
}

// MARK: - Provider Detected Card

private struct ProviderDetectedCard: View {
    let provider: EmailProviderPreset

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: provider.icon)
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 44, height: 44)
                .background(Color.teal.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.name)
                        .font(.headline)

                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Text("wizard.email.providerDetected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Provider Quick Button

private struct ProviderQuickButton: View {
    let provider: EmailProviderPreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: provider.icon)
                    .font(.subheadline)

                Text(provider.name)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Color(.systemGray6))
            .foregroundStyle(.primary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        StepEmailInput()
            .environmentObject(MailSetupState())
    }
}
