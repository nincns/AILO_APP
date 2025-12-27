// Views/Assistant/Modules/MailSetup/MailSetupWizard.swift
// AILO - Mail Setup Wizard
// Phase 2: Vollständige Implementierung folgt

import SwiftUI

/// Mail Setup Wizard - Placeholder für Phase 2
struct MailSetupWizard: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "envelope.badge.person.crop")
                .font(.system(size: 64))
                .foregroundStyle(.teal.gradient)

            Text("assistant.module.mail.title")
                .font(.title2.bold())

            Text("Phase 2: Wizard-Implementierung")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(Text("assistant.module.mail.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") {
                    dismiss()
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        MailSetupWizard()
    }
}
