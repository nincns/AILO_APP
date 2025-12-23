import SwiftUI
import UIKit

/// Typ des Anbieters – kann bei Bedarf erweitert werden.
enum AIProviderType: String, CaseIterable, Identifiable, Codable {
    case openAI = "OpenAI"
    case mistral = "Mistral"
    case ollama = "Ollama"
    case custom = "Custom"

    var id: String { rawValue }

    /// Sinnvolle Platzhalter je Typ
    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com"
        case .mistral: return "https://api.mistral.ai"
        case .ollama: return "http://localhost"
        case .custom: return ""
        }
    }

    var defaultPort: String {
        switch self {
        case .openAI: return "443"
        case .mistral: return "443"
        case .ollama: return "11434"
        case .custom: return ""
        }
    }

    /// Typische Standardmodelle je Typ (nur als Fallback-Anzeige)
    var defaultModelPlaceholder: String {
        switch self {
        case .openAI: return "gpt-5-chat-latest"
        case .mistral: return "mistral-large-latest"
        case .ollama: return "llama3"
        case .custom: return "model-id"
        }
    }
}

/// Konfiguration eines einzelnen Providers
struct AIProviderConfig: Identifiable, Codable, Equatable {
    var id: UUID = .init()
    var name: String
    var type: AIProviderType
    var baseURL: String
    var port: String
    var apiKey: String
    var model: String
    var temperature: Double

    init(
        id: UUID = .init(),
        name: String,
        type: AIProviderType,
        baseURL: String? = nil,
        port: String? = nil,
        apiKey: String = "",
        model: String? = nil,
        temperature: Double = 0.7
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.baseURL = baseURL ?? type.defaultBaseURL
        self.port = port ?? type.defaultPort
        self.apiKey = apiKey
        self.model = model ?? type.defaultModelPlaceholder
        self.temperature = temperature
    }
}

/// Editor für eine einzelne Provider-Config
struct AIEditor: View {
    @Binding var config: AIProviderConfig
    var onSave: ((AIProviderConfig) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var fetchedModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        Form {
            Section(header: Text("Allgemein").textCase(.uppercase)) {
                TextField("Anzeigename (z. B. „OpenAI Prod“)", text: $config.name)
                Picker("Typ", selection: $config.type) {
                    ForEach(AIProviderType.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .onChange(of: config.type) { oldValue, newValue in
                    // Immer die Defaults setzen wenn Provider-Typ wechselt
                    config.baseURL = newValue.defaultBaseURL
                    config.port    = newValue.defaultPort
                    config.model   = newValue.defaultModelPlaceholder
                    fetchedModels.removeAll()
                }
            }

            Section(header: Text("Verbindung").textCase(.uppercase)) {
                TextField("Server-Adresse", text: $config.baseURL, prompt: Text(config.type.defaultBaseURL).foregroundColor(.secondary))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Port", text: $config.port, prompt: Text(config.type.defaultPort).foregroundColor(.secondary))
                    .keyboardType(.numberPad)
                SecureField("API Key", text: $config.apiKey)
                    .textInputAutocapitalization(.never)
            }

            Section(header: Text("Modell").textCase(.uppercase)) {
                HStack(spacing: 8) {
                    Group {
                        if fetchedModels.isEmpty {
                            TextField(config.type.defaultModelPlaceholder, text: $config.model)
                                .textInputAutocapitalization(.never)
                        } else {
                            Picker("", selection: $config.model) {
                                ForEach(fetchedModels, id: \.self) { m in Text(m).tag(m) }
                            }
                            .labelsHidden()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isLoadingModels { ProgressView().controlSize(.small) }

                    Button {
                        fetchModels()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Modelle neu laden")
                }

                Slider(value: $config.temperature, in: 0...2, step: 0.1) {
                    Text("Temperatur")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                HStack { Spacer(); Text(String(format: "Temperatur: %.1f", config.temperature)).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("AI-Provider")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Sichern") {
                    // Haptisches Feedback für erfolgreichen Speichervorgang
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)

                    // Speichern
                    onSave?(config)

                    // Maske schließen
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Model-Fetching (OpenAI + Ollama)
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
        let key  = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoadingModels = true
        fetchedModels.removeAll()

        func finish(_ models: [String]) {
            DispatchQueue.main.async {
                // Duplikate entfernen (manche APIs wie Mistral liefern Modelle mehrfach)
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
            // Probieren wir OpenAI-kompatibel: /v1/models (nur mit Key sinnvoll)
            guard let url = URL(string: root + "/v1/models") else { return finish([]) }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let arr  = json["data"] as? [[String: Any]]
                else {
                    // Fallback: Ollama-Style versuchen
                    self.fetchOllamaLike(root: root, key: key, finish)
                    return
                }
                let ids = arr.compactMap { $0["id"] as? String }
                finish(ids)
            }.resume()

        case .ollama:
            fetchOllamaLike(root: root, key: key, finish)
        }
    }

    private func fetchOllamaLike(root: String, key: String, _ completion: @escaping ([String]) -> Void) {
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
                   let arr  = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) {
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
