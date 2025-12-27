// Views/Assistant/Modules/AISetup/AISetupSteps/AIStepProviderType.swift
// AILO - Wizard Step 1: Provider-Typ auswählen

import SwiftUI

struct AIStepProviderType: View {
    @EnvironmentObject var state: AISetupState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.system(size: 56))
                        .foregroundStyle(.purple.gradient)

                    Text("wizard.ai.provider.title")
                        .font(.title2.bold())

                    Text("wizard.ai.provider.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 20)

                // Provider Cards
                VStack(spacing: 12) {
                    ForEach(AIProviderType.allCases) { type in
                        ProviderTypeCard(
                            type: type,
                            isSelected: state.selectedType == type,
                            onSelect: {
                                withAnimation(.spring(response: 0.3)) {
                                    state.selectedType = type
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal)

                // Info Text für ausgewählten Provider
                ProviderInfoBox(type: state.selectedType)
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
    }
}

// MARK: - Provider Type Card

private struct ProviderTypeCard: View {
    let type: AIProviderType
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Icon
                Image(systemName: iconForType)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : .purple)
                    .frame(width: 48, height: 48)
                    .background(isSelected ? Color.purple : Color.purple.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.rawValue)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitleForType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Selection Indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .purple : .secondary)
                    .font(.title3)
            }
            .padding()
            .background(isSelected ? Color.purple.opacity(0.1) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.purple : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var iconForType: String {
        switch type {
        case .openAI: return "brain.head.profile"
        case .mistral: return "wind"
        case .anthropic: return "sparkles"
        case .ollama: return "desktopcomputer"
        case .custom: return "slider.horizontal.3"
        }
    }

    private var subtitleForType: LocalizedStringKey {
        switch type {
        case .openAI: return "wizard.ai.provider.openai.hint"
        case .mistral: return "wizard.ai.provider.mistral.hint"
        case .anthropic: return "wizard.ai.provider.anthropic.hint"
        case .ollama: return "wizard.ai.provider.ollama.hint"
        case .custom: return "wizard.ai.provider.custom.hint"
        }
    }
}

// MARK: - Provider Info Box

private struct ProviderInfoBox: View {
    let type: AIProviderType

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text(titleForType)
                    .font(.subheadline.weight(.semibold))
            }

            Text(descriptionForType)
                .font(.caption)
                .foregroundStyle(.secondary)

            if type.requiresAPIKey {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption)
                    Text("wizard.ai.provider.requiresKey")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption)
                    Text("wizard.ai.provider.noKeyRequired")
                        .font(.caption)
                }
                .foregroundStyle(.green)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var titleForType: LocalizedStringKey {
        switch type {
        case .openAI: return "wizard.ai.provider.openai.title"
        case .mistral: return "wizard.ai.provider.mistral.title"
        case .anthropic: return "wizard.ai.provider.anthropic.title"
        case .ollama: return "wizard.ai.provider.ollama.title"
        case .custom: return "wizard.ai.provider.custom.title"
        }
    }

    private var descriptionForType: LocalizedStringKey {
        switch type {
        case .openAI: return "wizard.ai.provider.openai.description"
        case .mistral: return "wizard.ai.provider.mistral.description"
        case .anthropic: return "wizard.ai.provider.anthropic.description"
        case .ollama: return "wizard.ai.provider.ollama.description"
        case .custom: return "wizard.ai.provider.custom.description"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AIStepProviderType()
            .environmentObject(AISetupState())
    }
}
