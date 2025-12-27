// Views/Assistant/AssistantModuleProtocol.swift
// AILO - Assistant Module Protocol
// Erweiterbare Architektur für Wizard-Module

import SwiftUI
import Combine

// MARK: - Assistant Module Protocol

/// Protocol für alle Assistenten-Module (Mail, Journey, AI, etc.)
protocol AssistantModule: Identifiable {
    var id: String { get }
    var title: String { get }
    var icon: String { get }
    var description: String { get }
    var isComplete: Bool { get }

    @ViewBuilder func makeView() -> AnyView
}

// MARK: - Wizard Step Protocol

/// Protocol für einzelne Wizard-Schritte
protocol WizardStep: Identifiable {
    var id: String { get }
    var title: String { get }
    var isValid: Bool { get }
}

// MARK: - Module Registry

/// Zentrale Registry für alle verfügbaren Module
final class AssistantModuleRegistry: ObservableObject {
    static let shared = AssistantModuleRegistry()

    @Published private(set) var modules: [any AssistantModule] = []

    private init() {
        registerDefaultModules()
    }

    private func registerDefaultModules() {
        // Mail Setup
        modules.append(MailSetupModule())

        // KI-Provider Setup
        modules.append(AISetupModule())

        // Weitere Module hier registrieren:
        // modules.append(JourneySetupModule())
    }

    func register(_ module: any AssistantModule) {
        if !modules.contains(where: { $0.id == module.id }) {
            modules.append(module)
        }
    }
}

// MARK: - Mail Setup Module

/// Mail-Setup Modul - Implementierung in MailSetupWizard.swift
struct MailSetupModule: AssistantModule {
    let id = "mail-setup"
    let title = String(localized: "assistant.module.mail.title")
    let icon = "envelope.badge.person.crop"
    let description = String(localized: "assistant.module.mail.description")

    var isComplete: Bool {
        // Prüfen ob mindestens ein Mail-Account existiert
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let accounts = try? JSONDecoder().decode([MailAccountConfig].self, from: data) else {
            return false
        }
        return !accounts.isEmpty
    }

    func makeView() -> AnyView {
        AnyView(MailSetupWizard())
    }
}

// MARK: - AI Setup Module

/// KI-Provider Setup Modul
struct AISetupModule: AssistantModule {
    let id = "ai-setup"
    let title = String(localized: "assistant.module.ai.title")
    let icon = "cpu"
    let description = String(localized: "assistant.module.ai.description")

    var isComplete: Bool {
        // Prüfen ob mindestens ein Provider mit funktionierender Konfiguration existiert
        guard let data = UserDefaults.standard.data(forKey: "config.ai.providers.list"),
              let providers = try? JSONDecoder().decode([AIProviderConfig].self, from: data) else {
            return false
        }
        // Mindestens ein Provider mit API-Key (außer Ollama, das keinen braucht)
        return providers.contains {
            !$0.apiKey.isEmpty || $0.type == .ollama
        }
    }

    func makeView() -> AnyView {
        AnyView(AISetupWizard())
    }
}
