// Views/Assistant/Modules/AISetup/AISetupSteps/AIStepModelTest.swift
// AILO - Wizard Step 3: Modell auswählen + Verbindungstest

import SwiftUI

struct AIStepModelTest: View {
    @EnvironmentObject var state: AISetupState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header mit Status
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

                // Model Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("wizard.ai.model.select")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack {
                        if !state.availableModels.isEmpty {
                            Picker("", selection: $state.selectedModel) {
                                ForEach(state.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                        } else {
                            TextField(state.selectedType.defaultModelPlaceholder, text: $state.selectedModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        Spacer()

                        // Refresh Button
                        Button {
                            Task { await fetchModels() }
                        } label: {
                            if state.isLoadingModels {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(state.isLoadingModels)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    // Model Quick-Select (wenn verfügbar)
                    if !state.availableModels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(state.availableModels.prefix(6), id: \.self) { model in
                                    Button {
                                        state.selectedModel = model
                                    } label: {
                                        Text(model)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(state.selectedModel == model ? Color.purple : Color(.systemGray5))
                                            .foregroundStyle(state.selectedModel == model ? .white : .primary)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // Temperature Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("wizard.ai.model.temperature")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(String(format: "%.1f", state.temperature))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.purple)
                    }

                    Slider(value: $state.temperature, in: 0...state.selectedType.maxTemperature, step: 0.1)
                        .tint(.purple)

                    HStack {
                        Text("wizard.ai.model.precise")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("wizard.ai.model.creative")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Max Tokens
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("wizard.ai.model.maxTokens")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(state.maxTokens)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.purple)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(state.maxTokens) },
                            set: { state.maxTokens = Int($0) }
                        ),
                        in: 256...8192,
                        step: 256
                    )
                    .tint(.purple)

                    Text("wizard.ai.model.maxTokensHint")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Test Button
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        if state.isTestingConnection {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: state.connectionTestResult == nil ? "play.fill" : "arrow.clockwise")
                        }
                        Text(state.connectionTestResult == nil ? "wizard.ai.model.test" : "wizard.ai.model.retry")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(state.isTestingConnection ? Color.gray : Color.purple)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(state.isTestingConnection || state.selectedModel.isEmpty)
                .padding(.horizontal)

                // Error Message
                if case .failure(let message) = state.connectionTestResult {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }

                // Success Message
                if state.connectionTestResult == .success {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("wizard.ai.model.successMessage")
                            .font(.subheadline)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                }

                Spacer(minLength: 40)
            }
        }
        .onAppear {
            // Auto-fetch models
            if state.availableModels.isEmpty && state.selectedModel.isEmpty {
                state.selectedModel = state.selectedType.defaultModelPlaceholder
                Task { await fetchModels() }
            }
        }
    }

    // MARK: - Computed Properties

    private var statusColor: Color {
        if state.isTestingConnection { return .blue }
        switch state.connectionTestResult {
        case .success: return .green
        case .failure: return .red
        case nil: return .purple
        }
    }

    private var statusIcon: String {
        switch state.connectionTestResult {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case nil: return "sparkles"
        }
    }

    private var statusTitle: LocalizedStringKey {
        if state.isTestingConnection { return "wizard.ai.model.testing" }
        switch state.connectionTestResult {
        case .success: return "wizard.ai.model.success"
        case .failure: return "wizard.ai.model.failed"
        case nil: return "wizard.ai.model.title"
        }
    }

    private var statusSubtitle: LocalizedStringKey {
        if state.isTestingConnection { return "wizard.ai.model.testingSubtitle" }
        switch state.connectionTestResult {
        case .success: return "wizard.ai.model.successSubtitle"
        case .failure: return "wizard.ai.model.failedSubtitle"
        case nil: return "wizard.ai.model.subtitle"
        }
    }

    // MARK: - API Calls

    private func fetchModels() async {
        state.isLoadingModels = true

        let config = state.buildProviderConfig()

        // Anthropic hat keine Models-API
        if state.selectedType == .anthropic {
            state.availableModels = [
                "claude-3-5-sonnet-20241022",
                "claude-3-opus-20240229",
                "claude-3-sonnet-20240229",
                "claude-3-haiku-20240307"
            ]
            if !state.availableModels.contains(state.selectedModel) {
                state.selectedModel = state.availableModels.first ?? ""
            }
            state.isLoadingModels = false
            return
        }

        // URL für Models-Endpoint
        guard var baseURL = URL(string: config.baseURL) else {
            state.isLoadingModels = false
            return
        }

        // Port hinzufügen
        if !config.port.isEmpty, config.port != "443" {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.port = Int(config.port)
            if let url = components?.url {
                baseURL = url
            }
        }

        let modelsURL: URL?
        if state.selectedType == .ollama {
            modelsURL = baseURL.appendingPathComponent("api/tags")
        } else {
            modelsURL = baseURL.appendingPathComponent("v1/models")
        }

        guard let url = modelsURL else {
            state.isLoadingModels = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: request)

            if state.selectedType == .ollama {
                // Ollama: {"models": [{"name": "llama3:8b", ...}]}
                struct OllamaResponse: Codable {
                    struct Model: Codable { let name: String }
                    let models: [Model]
                }
                if let response = try? JSONDecoder().decode(OllamaResponse.self, from: data) {
                    state.availableModels = response.models.map { $0.name }
                }
            } else {
                // OpenAI/Mistral: {"data": [{"id": "gpt-4", ...}]}
                struct OpenAIResponse: Codable {
                    struct Model: Codable { let id: String }
                    let data: [Model]
                }
                if let response = try? JSONDecoder().decode(OpenAIResponse.self, from: data) {
                    state.availableModels = response.data.map { $0.id }.sorted()
                }
            }

            // Aktuelles Modell behalten wenn in Liste
            if !state.selectedModel.isEmpty && !state.availableModels.contains(state.selectedModel) {
                state.availableModels.insert(state.selectedModel, at: 0)
            }

            print("✅ [AI Wizard] Loaded \(state.availableModels.count) models")

        } catch {
            print("⚠️ [AI Wizard] Failed to fetch models: \(error)")
        }

        state.isLoadingModels = false
    }

    private func testConnection() async {
        state.isTestingConnection = true
        state.connectionTestResult = nil

        let config = state.buildProviderConfig()

        print("🔌 [AI Wizard] Testing: \(config.baseURL) model=\(config.model)")

        // AIClient für Test nutzen
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AIClient.rewrite(
                baseURL: config.baseURL,
                port: config.port.isEmpty ? nil : config.port,
                apiKey: config.apiKey.isEmpty ? nil : config.apiKey,
                model: config.model,
                temperature: config.temperature,
                maxTokens: 50,
                prePrompt: "Reply with only the word: OK",
                userText: "Test"
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let response):
                        print("✅ [AI Wizard] Test successful: \(response.prefix(50))")
                        state.connectionTestResult = .success
                    case .failure(let error):
                        print("❌ [AI Wizard] Test failed: \(error)")
                        state.connectionTestResult = .failure(error.localizedDescription)
                    }
                    continuation.resume()
                }
            }
        }

        state.isTestingConnection = false
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AIStepModelTest()
            .environmentObject({
                let state = AISetupState()
                state.selectedType = .openAI
                state.selectedModel = "gpt-4o"
                return state
            }())
    }
}
