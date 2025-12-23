import SwiftUI
import Foundation

/// Zentrale Keys – falls du bereits eine eigene SettingsKeys.swift hast,
/// kannst du diese Konstanten dorther importieren und die Duplikate hier entfernen.
private enum K {
    static let categories          = "config.categories"
    static let micSensitivity      = "config.mic.sensitivity"
    static let silenceThresholdDB  = "config.mic.silenceDB"
    static let chunkSeconds        = "config.mic.chunkSeconds"
    static let speechLang          = "config.speech.lang"
    static let mailSettingsName   = "config.mail.settingsName"
}

struct ConfigView: View {
    // MARK: – Kategorien
    @State private var categories: [String] = []
    @State private var newCategory: String = ""

    // MARK: – Aufnahme / Erkennung
    @State private var micSensitivity: Double = 0.85      // 0.0 ... 1.0 (UI zeigt %)
    @State private var silenceThresholdDB: Double = -40   // dB, -60 ... 0
    @State private var chunkSeconds: Double = 2.0         // 1 ... 10 s
    @State private var speechLang: String = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    @State private var mailSettingsName: String = ""

    // Beispielsprachen (kannst du erweitern)
    private let availableSpeechLangs: [(code: String, name: String)] = [
        ("de-DE", "Deutsch (Deutschland)"),
        ("de-AT", "Deutsch (Österreich)"),
        ("de-CH", "Deutsch (Schweiz)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)")
    ]

    private let defaultCategories: [String] = ["Allgemein", "Netzwerk", "Dokumentation"]

    var body: some View {
        NavigationView {
            Form {
                // MARK: Kategorien
                Section(header: Text("config.section.categories").textCase(.uppercase)) {
                    NavigationLink("config.categories.manage") {
                        CategoriesView()
                    }
                }

                // MARK: Mikrofon / Aufnahme
                Section(header: Text("config.section.mic").textCase(.uppercase)) {
                    LabeledSlider(title: String(localized: "config.mic.sensitivity"),
                                  value: $micSensitivity,
                                  range: 0...1,
                                  display: micSensitivity.isNaN ? "N/A" : "\(Int((micSensitivity*100.0).rounded())) %")
                    .onChange(of: micSensitivity) { _, newValue in 
                        if !newValue.isNaN && !newValue.isInfinite {
                            persist(.mic) 
                        }
                    }

                    LabeledSlider(title: String(localized: "config.mic.silenceThreshold"),
                                  value: $silenceThresholdDB,
                                  range: -60...0,
                                  step: 1,
                                  display: silenceThresholdDB.isNaN ? "N/A" : "\(Int(silenceThresholdDB)) dB")
                    .onChange(of: silenceThresholdDB) { _, newValue in 
                        if !newValue.isNaN && !newValue.isInfinite {
                            persist(.mic) 
                        }
                    }

                    LabeledSlider(title: String(localized: "config.mic.chunkLength"),
                                  value: $chunkSeconds,
                                  range: 1...10,
                                  step: 1,
                                  display: chunkSeconds.isNaN ? "N/A" : "\(Int(chunkSeconds)) s")
                    .onChange(of: chunkSeconds) { _, newValue in 
                        if !newValue.isNaN && !newValue.isInfinite {
                            persist(.mic) 
                        }
                    }
                }

                // MARK: Sprache
                Section(header: Text("config.section.language").textCase(.uppercase)) {
                    Picker(String(localized: "config.language.speechRecognition"), selection: $speechLang) {
                        ForEach(availableSpeechLangs, id: \.code) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                    .onChange(of: speechLang) { persist(.speech) }
                }

                // MARK: Mail
                Section(header: Text("config.section.mail").textCase(.uppercase)) {
//                    TextField(String(localized: "config.mail.settingsName"), text: $mailSettingsName, prompt: Text(String(localized: "config.mail.settingsName.placeholder")))
//                        .textInputAutocapitalization(.words)
//                        .disableAutocorrection(true)
//                        .onChange(of: mailSettingsName) { persist(.mail) }
                    NavigationLink("config.nav.mailManager", destination: MailManager())
                }

                // MARK: AI – nur zwei Einträge: Pre-Prompts & Provider-Manager
                Section(header: Text("config.section.ai").textCase(.uppercase)) {
                    NavigationLink("config.nav.aiManager", destination: AIManagerView())
                    NavigationLink("config.nav.prePrompts", destination: PrePromptManager())
                }
            }
            .navigationTitle(Text("config.nav.title"))
            .onAppear(perform: loadFromDefaults)
        }
    }

    // MARK: – Helpers & Persistence
    private enum PersistGroup { case categories, mic, speech, mail }

    private func persist(_ group: PersistGroup) {
        let ud = UserDefaults.standard
        switch group {
        case .categories:
            if let data = try? JSONEncoder().encode(categories) { ud.set(data, forKey: K.categories) }
        case .mic:
            // Validate values before persisting to prevent NaN
            let validMicSensitivity = micSensitivity.isNaN || micSensitivity.isInfinite ? 0.85 : micSensitivity
            let validSilenceThreshold = silenceThresholdDB.isNaN || silenceThresholdDB.isInfinite ? -40 : silenceThresholdDB
            let validChunkSeconds = chunkSeconds.isNaN || chunkSeconds.isInfinite ? 2.0 : chunkSeconds
            
            print("🔧 DEBUG: Persisting mic values - sensitivity: \(validMicSensitivity), threshold: \(validSilenceThreshold), chunk: \(validChunkSeconds)")
            
            ud.set(validMicSensitivity, forKey: K.micSensitivity)
            ud.set(validSilenceThreshold, forKey: K.silenceThresholdDB)
            ud.set(validChunkSeconds, forKey: K.chunkSeconds)
        case .speech:
            let normalized = speechLang.replacingOccurrences(of: "_", with: "-")
            ud.set(normalized, forKey: K.speechLang)
        case .mail:
            ud.set(mailSettingsName, forKey: K.mailSettingsName)
        }
    }

    private func loadFromDefaults() {
        let ud = UserDefaults.standard
        // Kategorien
        if let data = ud.data(forKey: K.categories),
           let arr = try? JSONDecoder().decode([String].self, from: data) { categories = arr }
        else { categories = defaultCategories }
        
        // Mic - mit NaN-Schutz
        let rawMicSensitivity = ud.object(forKey: K.micSensitivity) as? Double ?? 0.85
        micSensitivity = rawMicSensitivity.isNaN || rawMicSensitivity.isInfinite ? 0.85 : rawMicSensitivity
        
        let rawSilenceThreshold = ud.object(forKey: K.silenceThresholdDB) as? Double ?? -40
        silenceThresholdDB = rawSilenceThreshold.isNaN || rawSilenceThreshold.isInfinite ? -40 : rawSilenceThreshold
        
        let rawChunkSeconds = ud.object(forKey: K.chunkSeconds) as? Double ?? 2
        chunkSeconds = rawChunkSeconds.isNaN || rawChunkSeconds.isInfinite ? 2 : rawChunkSeconds
        
        // Sprache
        speechLang = (ud.string(forKey: K.speechLang) ?? Locale.current.identifier).replacingOccurrences(of: "_", with: "-")
        mailSettingsName = ud.string(forKey: K.mailSettingsName) ?? ""
        
        print("🔧 DEBUG: Loaded config values - micSensitivity: \(micSensitivity), silenceThresholdDB: \(silenceThresholdDB), chunkSeconds: \(chunkSeconds)")
    }
}

// MARK: – Reusable Slider Row
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(display).foregroundColor(.secondary)
            }
            if let s = step {
                Slider(value: $value, in: range, step: s)
            } else {
                Slider(value: $value, in: range)
            }
        }
    }
}
