// Views/Assistant/Components/WizardProgressBar.swift
// AILO - Wizard Progress Indicator

import SwiftUI

struct WizardProgressBar: View {
    let steps: [WizardStepInfo]
    let currentStep: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                // Step Circle
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(stepColor(for: index))
                            .frame(width: 32, height: 32)

                        if index < currentStep {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: step.icon)
                                .font(.caption)
                                .foregroundStyle(index == currentStep ? .white : .secondary)
                        }
                    }

                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(index <= currentStep ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                // Connector Line
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < currentStep ? Color.teal : Color(.systemGray4))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                        .offset(y: -10)
                }
            }
        }
    }

    private func stepColor(for index: Int) -> Color {
        if index < currentStep {
            return .teal
        } else if index == currentStep {
            return .teal
        } else {
            return Color(.systemGray4)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 40) {
        WizardProgressBar(
            steps: [
                WizardStepInfo(title: "E-Mail", icon: "envelope"),
                WizardStepInfo(title: "Passwort", icon: "key"),
                WizardStepInfo(title: "Test", icon: "checkmark.circle"),
                WizardStepInfo(title: "Ordner", icon: "folder")
            ],
            currentStep: 0
        )

        WizardProgressBar(
            steps: [
                WizardStepInfo(title: "E-Mail", icon: "envelope"),
                WizardStepInfo(title: "Passwort", icon: "key"),
                WizardStepInfo(title: "Test", icon: "checkmark.circle"),
                WizardStepInfo(title: "Ordner", icon: "folder")
            ],
            currentStep: 2
        )
    }
    .padding()
}
