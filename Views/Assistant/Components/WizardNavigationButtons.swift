// Views/Assistant/Components/WizardNavigationButtons.swift
// AILO - Wizard Navigation Controls

import SwiftUI

struct WizardNavigationButtons: View {
    @Binding var currentStep: Int
    let totalSteps: Int
    let canProceed: Bool
    let isLastStep: Bool
    let onNext: () -> Void
    let onBack: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Back Button
            if currentStep > 0 {
                Button {
                    onBack()
                } label: {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("common.back")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemGray5))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            // Next / Finish Button
            Button {
                if isLastStep {
                    onFinish()
                } else {
                    onNext()
                }
            } label: {
                HStack {
                    Text(isLastStep ? "wizard.finish" : "common.next")

                    if !isLastStep {
                        Image(systemName: "chevron.right")
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canProceed ? Color.teal : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!canProceed)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        WizardNavigationButtons(
            currentStep: .constant(0),
            totalSteps: 4,
            canProceed: true,
            isLastStep: false,
            onNext: {},
            onBack: {},
            onFinish: {}
        )

        WizardNavigationButtons(
            currentStep: .constant(2),
            totalSteps: 4,
            canProceed: false,
            isLastStep: false,
            onNext: {},
            onBack: {},
            onFinish: {}
        )

        WizardNavigationButtons(
            currentStep: .constant(3),
            totalSteps: 4,
            canProceed: true,
            isLastStep: true,
            onNext: {},
            onBack: {},
            onFinish: {}
        )
    }
    .padding()
}
