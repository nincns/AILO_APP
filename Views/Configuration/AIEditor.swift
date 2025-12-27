// Views/Configuration/AIEditor.swift
// AILO - AI Provider Editor (Erweitert für OpenAI, Mistral, Ollama, Anthropic)

import SwiftUI
import UIKit

// MARK: - Provider Type

/// Typ des Anbieters
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case mistral = "Mistral"
    case anthropic = "Anthropic"
    case ollama = "Ollama"
    case custom = "Custom"

    var id: String { rawValue }

    /// Sinnvolle Platzhalter je Typ
    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com"
        case .mistral: return "https://api.mistral.ai"
        case .anthropic: return "https://api.anthropic.com"
        case .ollama: return "http://localhost"
        case .custom: return ""
        }
    }

    var defaultPort: String {
        switch self {
        case .openAI: return "443"
        case .mistral: return "443"
        case .anthropic: return "443"
        case .ollama: return "11434"
        case .custom: return ""
        }
    }

    /// Typische Standardmodelle je Typ
    var defaultModelPlaceholder: String {
        switch self {
        case .openAI: return "gpt-4o"
        case .mistral: return "mistral-large-latest"
        case .anthropic: return "claude-3-5-sonnet-20241022"
        case .ollama: return "llama3:8b"
        case .custom: return "model-id"
        }
    }

    /// Maximale Temperature je Provider
    var maxTemperature: Double {
        switch self {
        case .openAI: return 2.0
        case .mistral: return 1.0
        case .anthropic: return 1.0
        case .ollama: return 2.0
        case .custom: return 2.0
        }
    }

    /// Ob ein API-Key erforderlich ist
    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }

    /// API-Typ für Routing
    var apiStyle: APIStyle {
        switch self {
        case .openAI, .mistral: return .openAICompatible
        case .anthropic: return .anthropic
        case .ollama: return .ollama
        case .custom: return .openAICompatible // Standard-Fallback
        }
    }

    enum APIStyle {
        case openAICompatible  // /v1/chat/completions
        case anthropic         // /v1/messages (eigenes Format)
        case ollama            // /api/chat oder /api/generate
    }
}

// MARK: - Provider Config

/// Konfiguration eines einzelnen Providers
struct AIProviderConfig: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var name: String
    var type: AIProviderType
    var baseURL: String
    var port: String
    var apiKey: String
    var model: String

    // Generierungsparameter
    var temperature: Double
    var maxTokens: Int
    var topP: Double?

    // CodingKeys für Migration
    private enum CodingKeys: String, CodingKey {
        case id, name, type, baseURL, port, apiKey, model
        case temperature, maxTokens, topP
    }

    init(
        id: UUID = .init(),
        name: String,
        type: AIProviderType,
        baseURL: String? = nil,
        port: String? = nil,
        apiKey: String = "",
        model: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        topP: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL ?? type.defaultBaseURL
        self.port = port ?? type.defaultPort
        self.apiKey = apiKey
        self.model = model ?? type.defaultModelPlaceholder
        self.temperature = min(temperature, type.maxTemperature)
        self.maxTokens = maxTokens
        self.topP = topP
    }

    // MARK: - Codable Migration

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(AIProviderType.self, forKey: .type)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        port = try container.decode(String.self, forKey: .port)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        model = try container.decode(String.self, forKey: .model)
        temperature = try container.decode(Double.self, forKey: .temperature)

        // Migration: Neue Felder mit Defaults
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(port, forKey: .port)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(model, forKey: .model)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(topP, forKey: .topP)
    }
}

// MARK: - AI Editor View

/// Editor für eine einzelne Provider-Config
struct AIEditor: View {
    @Binding var config: AIProviderConfig
    var onSave: ((AIProviderConfig) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var fetchedModels: [String] = []
    @State private var isLoadingModels = false
    @State private var showAdvancedSettings = false
    @State private var testResult: TestResult?
    @State private var isTesting = false

    enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            // MARK: - Allgemein
            Section(header: Text("aiEditor.section.general")) {
                TextField(String(localized: "aiEditor.placeholder.displayName"), text: $config.name)

                Picker(String(localized: "aiEditor.field.type"), selection: $config.type) {
                    ForEach(AIProviderType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .onChange(of: config.type) { _, newValue in
                    config.baseURL = newValue.defaultBaseURL
                    config.port = newValue.defaultPort
                    config.model = newValue.defaultModelPlaceholder
                    config.temperature = min(config.temperature, newValue.maxTemperature)
                    fetchedModels.removeAll()
                    testResult = nil
                }
            }

            // MARK: - Verbindung
            Section(header: Text("aiEditor.section.connection")) {
                TextField(String(localized: "aiEditor.field.baseURL"), text: $config.baseURL, prompt: Text(config.type.defaultBaseURL).foregroundColor(.secondary))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                TextField(String(localized: "aiEditor.field.port"), text: $config.port, prompt: Text(config.type.defaultPort).foregroundColor(.secondary))
                    .keyboardType(.numberPad)

                if config.type.requiresAPIKey {
                    SecureField(String(localized: "aiEditor.field.apiKey"), text: $config.apiKey)
                        .textInputAutocapitalization(.never)

                    // Anthropic-spezifischer Hinweis
                    if config.type == .anthropic {
                        Text("aiEditor.hint.anthropic")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // MARK: - Modell
            Section(header: Text("aiEditor.section.model")) {
                HStack(spacing: 8) {
                    Group {
                        if fetchedModels.isEmpty {
                            TextField(config.type.defaultModelPlaceholder, text: $config.model)
                                .textInputAutocapitalization(.never)
                        } else {
                            Picker("", selection: $config.model) {
                                ForEach(fetchedModels, id: \.self) { m in
                                    Text(m).tag(m)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isLoadingModels {
                        ProgressView().controlSize(.small)
                    }

                    Button {
                        fetchModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("aiEditor.a11y.reloadModels"))
                }

                // Temperature
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $config.temperature, in: 0...config.type.maxTemperature, step: 0.1) {
                        Text("aiEditor.field.temperature")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text(String(format: "%.0f", config.type.maxTemperature))
                    }

                    HStack {
                        Spacer()
                        Text(String(format: String(localized: "aiEditor.temperature.value"), config.temperature))
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }

                // Max Tokens
                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $config.maxTokens, in: 256...16384, step: 256) {
                        HStack {
                            Text("aiEditor.field.maxTokens")
                            Spacer()
                            Text("\(config.maxTokens)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("aiEditor.hint.maxTokens")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // MARK: - Erweiterte Einstellungen
            Section {
                DisclosureGroup(
                    isExpanded: $showAdvancedSettings,
                    content: {
                        // Top P
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Top P")
                                Spacer()
                                Text(String(format: "%.2f", config.topP ?? 1.0))
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { config.topP ?? 1.0 },
                                    set: { config.topP = $0 < 1.0 ? $0 : nil }
                                ),
                                in: 0...1,
                                step: 0.05
                            )

                            Text("aiEditor.hint.topP")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    },
                    label: {
                        Label("aiEditor.section.advanced", systemImage: "slider.horizontal.3")
                    }
                )
            }

            // MARK: - Verbindungstest
            Section {
                Button {
                    testConnection()
                } label: {
                    HStack {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: testResultIcon)
                                .foregroundStyle(testResultColor)
                        }

                        Text(isTesting ? "aiEditor.test.testing" : "aiEditor.test.button")

                        Spacer()

                        if let result = testResult {
                            switch result {
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failure:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .disabled(isTesting)

                if case .failure(let message) = testResult {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Text("aiEditor.title"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "aiEditor.action.save")) {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    onSave?(config)
                    dismiss()
                }
            }
        }
    }

    // MARK: - Computed Properties

    private var testResultIcon: String {
        switch testResult {
        case .success: return "checkmark.circle"
        case .failure: return "xmark.circle"
        case nil: return "network"
        }
    }

    private var testResultColor: Color {
        switch testResult {
        case .success: return .green
        case .failure: return .red
        case nil: return .secondary
        }
    }

    // MARK: - Connection Test

    private func testConnection() {
        isTesting = true
        testResult = nil

        AIClient.rewrite(
            baseURL: config.baseURL,
            port: config.port.isEmpty ? nil : config.port,
            apiKey: config.apiKey.isEmpty ? nil : config.apiKey,
            model: config.model,
            temperature: config.temperature,
            maxTokens: 50, // Kleiner Test
            prePrompt: "Reply with only: OK",
            userText: "Test"
        ) { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success:
                    testResult = .success
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                case .failure(let error):
                    testResult = .failure(error.localizedDescription)
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.error)
                }
            }
        }
    }
}

// MARK: - Model Fetching

extension AIEditor {
    private func effectiveRoot() -> String {
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = config.port.trimmingCharacters(in: .whitespacesAndNewlines)

        var baseURLString = base.hasSuffix("/") ? String(base.dropLast()) : base
        if !port.isEmpty,
           port != "443",
           URL(string: baseURLString)?.port == nil {
            baseURLString += ":\(port)"
        }
        return baseURLString
    }

    private func fetchModels() {
        let root = effectiveRoot()
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoadingModels = true
        fetchedModels.removeAll()

        func finish(_ models: [String]) {
            DispatchQueue.main.async {
                let uniqueModels = Array(Set(models)).sorted()
                self.fetchedModels = uniqueModels
                self.isLoadingModels = false
                if !uniqueModels.isEmpty, !uniqueModels.contains(self.config.model) {
                    self.config.model = uniqueModels.first!
                }
            }
        }

        switch config.type {
        case .openAI, .mistral, .custom:
            fetchOpenAIModels(root: root, key: key, finish)

        case .anthropic:
            // Anthropic hat keine Models-API, feste Liste
            finish(["claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-3-haiku-20240307", "claude-3-sonnet-20240229"])

        case .ollama:
            fetchOllamaModels(root: root, key: key, finish)
        }
    }

    private func fetchOpenAIModels(root: String, key: String, _ completion: @escaping ([String]) -> Void) {
        guard let url = URL(string: root + "/v1/models") else { return completion([]) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let arr = json["data"] as? [[String: Any]]
            else {
                return completion([])
            }
            let ids = arr.compactMap { $0["id"] as? String }
            completion(ids)
        }.resume()
    }

    private func fetchOllamaModels(root: String, key: String, _ completion: @escaping ([String]) -> Void) {
        let candidates = ["/api/tags", "/api/models"]
        func tryNext(_ i: Int) {
            guard i < candidates.count else { return completion([]) }
            guard let url = URL(string: root + candidates[i]) else { return tryNext(i + 1) }

            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) {
                    let names = arr.compactMap { ($0["name"] as? String) ?? ($0["id"] as? String) }
                    completion(names)
                } else {
                    tryNext(i + 1)
                }
            }.resume()
        }
        tryNext(0)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AIEditor(config: .constant(AIProviderConfig(name: "Test", type: .openAI)))
    }
}
