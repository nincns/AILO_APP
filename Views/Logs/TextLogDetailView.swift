//Features/Logs/TextLogDetailView.swift
import SwiftUI
import Foundation

// AIPrePromptPreset is imported from Database/Models/AIPrePromptPreset.swift
struct TextLogDetailView: View {
    let entry: LogEntry
    let entryID: UUID
    @EnvironmentObject private var store: DataStore
    @State private var useAI: Bool = false
    @State private var aiText: String = ""

    @State private var isProcessing: Bool = false
    @State private var errorMessage: String? = nil

    // Editing state
    @State private var isEditing: Bool = false
    @State private var editTitle: String = ""
    @State private var editText: String = ""

    // Reminder state
    @State private var reminderOn: Bool = false
    @State private var reminderDate: Date = Date().addingTimeInterval(3600)

    // Preset state
    @State private var presets: [AIPrePromptPreset] = []
    @State private var selectedPresetID: UUID? = nil
    @State private var showingPresetManager: Bool = false

    init(entry: LogEntry) {
        self.entry = entry
        self.entryID = entry.id
        _useAI = State(initialValue: entry.useAI ?? false)
        _aiText = State(initialValue: entry.aiText ?? "")
        _reminderOn = State(initialValue: entry.reminderDate != nil)
        _reminderDate = State(initialValue: entry.reminderDate ?? Date().addingTimeInterval(3600))
        _editTitle = State(initialValue: entry.title ?? "")
        _editText  = State(initialValue: entry.text ?? "")
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        if isEditing {
                            TextField(String(localized: "logDetail.field.title.placeholder"), text: $editTitle)
                                .font(.title3).bold()
                        } else {
                            let t = editTitle
                            Text(t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "logDetail.field.title.placeholder") : t)
                                .font(.title3).bold()
                        }
                        Spacer()
                        Button(action: {
                            if isEditing {
                                var updated = entry
                                // Titel bereinigen und setzen
                                let trimmedTitle = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                                updated.title = trimmedTitle.isEmpty ? nil : trimmedTitle

                                if useAI {
                                    // AI‑Text speichern
                                    self.aiText = editText
                                    updated.aiText = self.aiText
                                } else {
                                    // Original‑Text speichern
                                    updated.text = editText
                                }
                                // Persistiere die Auswahl, welche Version aktiv ist
                                updated.useAI = useAI
                                store.update(updated)
                            } else {
                                // In den Editiermodus wechseln → Puffer anhand useAI wählen und Titel aus Store aktualisieren
                                let latest = store.entries.first(where: { $0.id == entryID })
                                self.editTitle = latest?.title ?? entry.title ?? ""
                                if useAI {
                                    self.editText = self.aiText
                                } else {
                                    let latestOriginal = latest?.text ?? entry.text ?? ""
                                    self.editText = latestOriginal
                                }
                            }
                            withAnimation { isEditing.toggle() }
                        }) {
                            Text(isEditing ? "logDetail.action.save" : "logDetail.action.edit")
                                .font(.callout)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(isEditing ? "logDetail.a11y.saveChanges" : "logDetail.a11y.enableEditMode"))
                    }
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let cat = entry.category, !cat.isEmpty {
                            Text(cat)
                                .font(.caption2)
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.vertical, 2).padding(.horizontal, 6)
                                .background(Color.gray.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    // 1. Zeile: links Datetimepicker (Reminder)
                    HStack(spacing: 8) {
                        Toggle("", isOn: $reminderOn)
                            .labelsHidden()
                            .accessibilityLabel(Text("logDetail.a11y.reminderActive"))
                        if reminderOn {
                            DatePicker("", selection: $reminderDate, displayedComponents: [.date, .hourAndMinute])
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        } else {
                            Image(systemName: "bell")
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Rechts: Sprechblase und daneben der KI‑Schalter
                        Button {
                            showingPresetManager = true
                        } label: {
                            Text("💬")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)

                        Toggle("", isOn: $useAI)
                            .labelsHidden()
                            .onChange(of: useAI) { _, newVal in
                                // Persist immediately so LogsView updates its displayed text for this entry
                                persistAIState(newUseAI: newVal)

                                // Keep editor buffer in sync when toggling during edit mode
                                if isEditing {
                                    if newVal {
                                        editText = aiText
                                    } else {
                                        let latestOriginal = store.entries.first(where: { $0.id == entryID })?.text ?? entry.text ?? ""
                                        editText = latestOriginal
                                    }
                                }

                                // If AI is turned on and we have no AI text yet, trigger a rewrite
                                if newVal {
                                    if aiText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        requestAIRewrite()
                                    }
                                }
                            }
                    }

                    // 2. Zeile: links KI‑Schalter, mittig Preset‑Dropdown, rechts Refresh + AI Text
                    HStack(alignment: .center, spacing: 12) {
                        // Links: Label "Original Text"
                        HStack(spacing: 8) {
                            Text("logDetail.label.originalText")
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Mitte: Preset‑Picker (Dropdown)
                        HStack {
                            if !presets.isEmpty {
                                Picker(String(localized: "logDetail.preset.label"), selection: $selectedPresetID) {
                                    ForEach(presets) { p in
                                        Text(p.name).tag(p.id as UUID?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedPresetID) { _, _ in
                                    persistSelectedPreset()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        // Rechts: Refresh + "AI Text"
                        HStack(spacing: 12) {
                            if useAI {
                                if isProcessing {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Button { requestAIRewrite() } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(aiText.isEmpty ? String(localized: "logDetail.action.aiRewrite") : String(localized: "logDetail.action.refreshAI"))
                                }
                            }
                            Text("logDetail.label.aiText")
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Divider()
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Group {
                        if isEditing {
                            TextEditor(text: $editText)
                                .frame(minHeight: 160)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.gray.opacity(0.2))
                                )
                        } else {
                            if useAI {
                                if aiText.isEmpty {
                                    Text("logDetail.ai.empty")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(aiText)
                                        .onChange(of: aiText) { persistAITextOnly() }
                                }
                            } else {
                                let latestOriginal = store.entries.first(where: { $0.id == entryID })?.text ?? entry.text ?? ""
                                Text(latestOriginal)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(Text("logDetail.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadPresets()
                // Do not auto-request AI rewrite here; user can trigger via the refresh button.
            }
            .sheet(isPresented: $showingPresetManager, onDismiss: { loadPresets() }) {
                PrePromptManager()
            }
            .onChange(of: reminderOn) { _, _ in
                persistReminderState()
            }
            .onChange(of: reminderDate) { _, _ in
                if reminderOn { persistReminderState() }
            }
        }
    }

    private func persistAIState(newUseAI: Bool) {
        var updated = entry
        updated.useAI = newUseAI
        updated.aiText = aiText
        store.update(updated)
    }

    private func persistAITextOnly() {
        var updated = entry
        updated.aiText = aiText
        store.update(updated)
    }

    // MARK: - AI PrePrompt Presets
    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
           let arr = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) { presets = arr }
        else { presets = [] }
        if let sel = UserDefaults.standard.string(forKey: kAISelectedPresetKey), let uuid = UUID(uuidString: sel) {
            selectedPresetID = uuid
        }
        if selectedPresetID == nil, let first = presets.first?.id {
            selectedPresetID = first
        }
    }
    private func persistSelectedPreset() {
        if let id = selectedPresetID { UserDefaults.standard.set(id.uuidString, forKey: kAISelectedPresetKey) }
    }
    private func selectedPresetText() -> String? {
        guard let id = selectedPresetID, let item = presets.first(where: { $0.id == id }) else { return nil }
        return item.text
    }

    // MARK: - AI Networking
    private func requestAIRewrite() {
        guard !isProcessing else { return }
        // Immer den aktuell gespeicherten Originaltext (nicht die UI‑Anzeige) verwenden
        let latestOriginal: String = {
            if let fresh = store.entries.first(where: { $0.id == entryID })?.text {
                return fresh
            }
            return entry.text
        }() ?? ""
        let original = latestOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        isProcessing = true
        errorMessage = nil

        // Load config (legacy keys first)
        var addr = (UserDefaults.standard.string(forKey: kAIServerAddress) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var portStr = (UserDefaults.standard.string(forKey: kAIServerPort) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var key  = UserDefaults.standard.string(forKey: kAIAPIKey) ?? ""
        var model = (UserDefaults.standard.string(forKey: kAIModel) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let pre = selectedPresetText() ?? (UserDefaults.standard.string(forKey: kAIPrePrompt) ?? "")

        // Fallback to selected provider (new manager) if legacy empty
        if addr.isEmpty || model.isEmpty {
            let fb = selectedProviderFallback()
            if addr.isEmpty, let b = fb.baseURL { addr = b }
            if portStr.isEmpty, let p = fb.port { portStr = p }
            if key.isEmpty, let k = fb.apiKey { key = k }
            if model.isEmpty, let m = fb.model { model = m }
        }
        // Sensible defaults
        if model.isEmpty { model = "llama3:8b" }

        // Build base URL (https default), omit :443
        guard let base = buildRootURL(address: addr, port: portStr) else {
            self.isProcessing = false
            self.errorMessage = String(localized: "logDetail.error.invalidServer")
            return
        }

        // First try OpenAI-compatible /v1/chat/completions, then Ollama-like fallback
        callOpenAI(baseURL: base, apiKey: key, model: model, prePrompt: pre, userText: original) { text, err in
            if let text = text {
                DispatchQueue.main.async {
                    self.aiText = text
                    self.persistAITextOnly()
                    self.isProcessing = false
                }
            } else {
                // Fallback to Ollama
                callOllama(baseURL: base, apiKey: key, model: model, prePrompt: pre, userText: original) { text2, err2 in
                    DispatchQueue.main.async {
                        if let t2 = text2 {
                            self.aiText = t2
                            self.persistAITextOnly()
                            self.isProcessing = false
                        } else {
                            self.errorMessage = err2 ?? err ?? String(localized: "logDetail.error.aiFailed")
                            self.isProcessing = false
                        }
                    }
                }
            }
        }
    }

    private func buildRootURL(address: String, port: String?) -> URL? {
        var addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return nil }
        // autocorrect common mistakes
        let lower = addr.lowercased()
        if lower.hasPrefix("https//") && !addr.contains("://") { addr = "https://" + addr.dropFirst("https//".count) }
        if lower.hasPrefix("http//")  && !addr.contains("://") { addr = "http://"  + addr.dropFirst("http//".count) }
        if !addr.contains("://") { addr = "https://" + addr }
        addr = addr.replacingOccurrences(of: "\\", with: "/")
        guard let comps = URLComponents(string: addr),
              let scheme = comps.scheme,
              let host = comps.host, !host.isEmpty else { return nil }
        var root = URLComponents()
        root.scheme = scheme
        root.host = host
        let p = (port ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Int(p), v > 0, v != 443, v < 65536 { root.port = v } // do not append :443
        root.path = ""
        return root.url
    }

    private func selectedProviderFallback() -> (baseURL: String?, port: String?, apiKey: String?, model: String?) {
        let ud = UserDefaults.standard
        let listKey = "config.ai.providers.list"
        let selKey  = "config.ai.providers.selected"
        struct ProviderLite: Codable {
            let id: String?
            let baseURL: String?
            let port: String?
            let apiKey: String?
            let model: String?
        }
        guard let data = ud.data(forKey: listKey),
              let arr  = try? JSONDecoder().decode([ProviderLite].self, from: data) else {
            return (nil, nil, nil, nil)
        }
        let selID = ud.string(forKey: selKey)
        let chosen = arr.first { $0.id == selID } ?? arr.first
        return (chosen?.baseURL, chosen?.port, chosen?.apiKey, chosen?.model)
    }

    // OpenAI-compatible chat completions
    private func callOpenAI(baseURL: URL, apiKey: String, model: String, prePrompt: String, userText: String, completion: @escaping (String?, String?) -> Void) {
        guard let url = URL(string: "/v1/chat/completions", relativeTo: baseURL) else { completion(nil, String(localized: "logDetail.error.invalidURL")); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let messages: [[String: String]] = [
            ["role": "system", "content": prePrompt.isEmpty ? "You are a helpful editor. Rewrite the given text for clarity and correctness." : prePrompt],
            ["role": "user",   "content": userText]
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            // Some models (e.g. gpt-4o-mini) only support temperature=1, so we fix it for now until configuration is added later.
            "temperature": 1
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(nil, err.localizedDescription); return }
            guard let data = data else { completion(nil, String(localized: "logDetail.error.emptyResponse")); return }
            // Parse OpenAI-like JSON; if das fehlschlägt, rohen Text verwenden
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                completion(content, nil)
            } else if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completion(raw, nil)
            } else {
                completion(nil, String(localized: "logDetail.error.openaiParsing"))
            }
        }.resume()
    }

    // Ollama-like fallback (non-streaming)
    private func callOllama(baseURL: URL, apiKey: String, model: String, prePrompt: String, userText: String, completion: @escaping (String?, String?) -> Void) {
        // prefer /api/chat if available (non-stream assumed); otherwise /api/generate
        if let url = URL(string: "/api/chat", relativeTo: baseURL) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty { req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let body: [String: Any] = [
                "model": model,
                "stream": false,
                "messages": [
                    ["role": "system", "content": prePrompt.isEmpty ? "You are a helpful editor. Rewrite the given text for clarity and correctness." : prePrompt],
                    ["role": "user",   "content": userText]
                ]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let err = err { completion(nil, err.localizedDescription); return }
                guard let data = data else { completion(nil, String(localized: "logDetail.error.emptyResponse")); return }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let msg = (json["message"] as? [String: Any])?["content"] as? String {
                        completion(msg, nil); return
                    }
                    if let resp = json["response"] as? String { completion(resp, nil); return }
                }
                // RAW-Fallback: falls Server Plaintext liefert
                if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(raw, nil); return
                }
                completion(nil, String(localized: "logDetail.error.ollamaParsing"))
            }.resume()
            return
        }
        // /api/generate fallback
        if let url = URL(string: "/api/generate", relativeTo: baseURL) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if !apiKey.isEmpty { req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            let prompt = prePrompt.isEmpty ? userText : "\(prePrompt)\n\n---\n\n\(userText)"
            let body: [String: Any] = [
                "model": model,
                "prompt": prompt,
                "stream": false
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let err = err { completion(nil, err.localizedDescription); return }
                guard let data = data else { completion(nil, String(localized: "logDetail.error.emptyResponse")); return }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let resp = json["response"] as? String {
                    completion(resp, nil)
                } else if let raw = String(data: data, encoding: .utf8), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    completion(raw, nil)
                } else {
                    completion(nil, String(localized: "logDetail.error.ollamaParsing"))
                }
            }.resume()
        } else {
            completion(nil, String(localized: "logDetail.error.invalidURL"))
        }
    }
    private func persistReminderState() {
        var updated = entry
        updated.reminderDate = reminderOn ? reminderDate : nil
        store.update(updated)
    }
}
