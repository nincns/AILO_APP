// Views/Assistant/Modules/AISetup/AISetupWizard.swift
// AILO - AI Provider Setup Wizard

import SwiftUI

// MARK: - AI Setup State

@MainActor
final class AISetupState: ObservableObject {
    // Step 1: Provider-Auswahl
    @Published var selectedType: AIProviderType = .openAI

    // Step 2: Verbindung
    @Published var displayName: String = ""
    @Published var baseURL: String = ""
    @Published var port: String = ""
    @Published var apiKey: String = ""

    // Step 3: Modell & Parameter
    @Published var selectedModel: String = ""
    @Published var availableModels: [String] = []
    @Published var isLoadingModels: Bool = false
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 2048

    // Test
    @Published var isTestingConnection: Bool = false
    @Published var connectionTestResult: ConnectionTestResult?

    // Navigation
    @Published var currentStep: Int = 0
    @Published var isComplete: Bool = false
    @Published var errorMessage: String?
    @Published var isSaving: Bool = false

    enum ConnectionTestResult: Equatable {
        case success
        case failure(String)
    }

    // MARK: - Computed Properties

    var canProceedFromStep1: Bool {
        true // Typ ist immer ausgewählt
    }

    var canProceedFromStep2: Bool {
        let hasURL = !effectiveBaseURL.isEmpty
        let hasKey = !selectedType.requiresAPIKey || !apiKey.isEmpty
        return hasURL && hasKey
    }

    var canFinish: Bool {
        !selectedModel.isEmpty && connectionTestResult == .success
    }

    var effectiveBaseURL: String {
        baseURL.isEmpty ? selectedType.defaultBaseURL : baseURL
    }

    var effectivePort: String {
        port.isEmpty ? selectedType.defaultPort : port
    }

    var effectiveDisplayName: String {
        displayName.isEmpty ? selectedType.rawValue : displayName
    }

    // MARK: - Methods

    func applyTypeDefaults() {
        baseURL = selectedType.defaultBaseURL
        port = selectedType.defaultPort
        selectedModel = selectedType.defaultModelPlaceholder
        displayName = selectedType.rawValue
        temperature = 0.7
        maxTokens = 2048
        availableModels = []
        connectionTestResult = nil
    }

    func buildProviderConfig() -> AIProviderConfig {
        AIProviderConfig(
            name: effectiveDisplayName,
            type: selectedType,
            baseURL: effectiveBaseURL,
            port: effectivePort,
            apiKey: apiKey,
            model: selectedModel,
            temperature: min(temperature, selectedType.maxTemperature),
            maxTokens: maxTokens
        )
    }

    func reset() {
        selectedType = .openAI
        displayName = ""
        baseURL = ""
        port = ""
        apiKey = ""
        selectedModel = ""
        availableModels = []
        temperature = 0.7
        maxTokens = 2048
        connectionTestResult = nil
        currentStep = 0
        isComplete = false
        errorMessage = nil
        isSaving = false
    }
}

// MARK: - AI Setup Wizard View

struct AISetupWizard: View {
    @StateObject private var state = AISetupState()
    @Environment(\.dismiss) private var dismiss

    @State private var showCompletionAlert = false
    @State private var savedProviderName = ""

    private let steps = [
        WizardStepInfo(title: "wizard.ai.step.provider", icon: "cpu"),
        WizardStepInfo(title: "wizard.ai.step.connection", icon: "link"),
        WizardStepInfo(title: "wizard.ai.step.model", icon: "sparkles")
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
                AIStepProviderType()
                    .environmentObject(state)
                    .tag(0)

                AIStepConnection()
                    .environmentObject(state)
                    .tag(1)

                AIStepModelTest()
                    .environmentObject(state)
                    .tag(2)
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
        .navigationTitle(Text("wizard.ai.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("common.cancel") {
                    dismiss()
                }
            }
        }
        .alert("wizard.ai.complete.title", isPresented: $showCompletionAlert) {
            Button("wizard.ai.complete.addAnother") {
                state.reset()
            }
            Button("common.done") {
                dismiss()
            }
        } message: {
            Text("wizard.ai.complete.message \(savedProviderName)")
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
        case 2: return state.canFinish
        default: return false
        }
    }

    private func handleNext() {
        switch state.currentStep {
        case 0:
            state.applyTypeDefaults()
            state.currentStep = 1
        case 1:
            state.currentStep = 2
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
            await saveProvider()
        }
    }

    private func saveProvider() async {
        state.isSaving = true

        let config = state.buildProviderConfig()

        // AIManager zum Speichern nutzen
        let manager = AIManager()
        manager.add(config)

        // Als aktiv setzen wenn erster Provider
        if manager.providers.count == 1 {
            manager.select(config.id)
        }

        print("✅ [AI Wizard] Saved provider: \(config.name)")

        state.isSaving = false
        state.isComplete = true
        savedProviderName = config.name
        showCompletionAlert = true
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AISetupWizard()
    }
}
