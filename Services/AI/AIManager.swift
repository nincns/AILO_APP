import SwiftUI
import Combine

/// Persistenz-Keys nur für den Manager
private enum AIKeys {
    static let providers = "config.ai.providers.list"
    static let selected  = "config.ai.providers.selected"
}

/// Zentrale Verwaltung der Provider + Auswahl des aktiven
final class AIManager: ObservableObject {
    @Published var providers: [AIProviderConfig] = []
    @Published var selectedProviderID: UUID?

    init() { load() }

    func add(_ cfg: AIProviderConfig) {
        providers.append(cfg)
        if selectedProviderID == nil { selectedProviderID = cfg.id }
        save()
    }

    func update(_ cfg: AIProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == cfg.id }) {
            providers[idx] = cfg
            save()
        }
    }

    func remove(at offsets: IndexSet) {
        providers.remove(atOffsets: offsets)
        if let sel = selectedProviderID, !providers.contains(where: { $0.id == sel }) {
            selectedProviderID = providers.first?.id
        }
        save()
    }

    func select(_ id: UUID) {
        selectedProviderID = id
        save()
    }

    func selectedProvider() -> AIProviderConfig? {
        guard let id = selectedProviderID else { return nil }
        return providers.first(where: { $0.id == id })
    }

    // MARK: Persistence
    private func save() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(providers) {
            ud.set(data, forKey: AIKeys.providers)
        }
        ud.set(selectedProviderID?.uuidString, forKey: AIKeys.selected)
    }

    private func load() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: AIKeys.providers),
           let arr = try? JSONDecoder().decode([AIProviderConfig].self, from: data) {
            providers = arr
        } else {
            // Erstbefüllung: ein AILO-Network-Eintrag als Beispiel
            providers = [
                AIProviderConfig(
                    name: "AILO Network",
                    type: .custom,
                    baseURL: "https://api.ailo.network",
                    port: "443",
                    apiKey: "",
                    model: "llama3:8b"
                )
            ]
        }
        if let sel = ud.string(forKey: AIKeys.selected),
           let uuid = UUID(uuidString: sel),
           providers.contains(where: { $0.id == uuid }) {
            selectedProviderID = uuid
        } else {
            selectedProviderID = providers.first?.id
        }
        save() // persist immediately so AIClient fallback can read on first launch
    }
}

/// UI: Liste der Provider + „Radio“-Auswahl + Bearbeiten
struct AIManagerView: View {
    @StateObject private var manager = AIManager()
    @State private var newProviderSheet = false
    @State private var showEditSheet = false
    @State private var editBuffer: AIProviderConfig = AIProviderConfig(name: "", type: .custom)
    @State private var draft: AIProviderConfig = AIProviderConfig(name: String(localized: "aiManager.placeholder.newProvider"), type: .openAI)
    
    private func binding(for id: UUID) -> Binding<AIProviderConfig> {
        Binding<AIProviderConfig>(
            get: {
                manager.providers.first(where: { $0.id == id }) ?? manager.providers.first ?? AIProviderConfig(name: "", type: .custom)
            },
            set: { updated in
                manager.update(updated)
            }
        )
    }

    var body: some View {
        Group {
            List {
                ForEach(manager.providers) { cfg in
                    NavigationLink {
                        AIEditor(config: binding(for: cfg.id)) { updated in
                            manager.update(updated)
                        }
                    } label: {
                        HStack {
                            Image(systemName: manager.selectedProviderID == cfg.id ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(.accentColor)
                                .onTapGesture { manager.select(cfg.id) }
                            VStack(alignment: .leading) {
                                Text(cfg.name).font(.headline)
                                Text("\(cfg.type.rawValue) • \(cfg.baseURL)\(cfg.port.isEmpty ? "" : ":\(cfg.port)")")
                                    .font(.subheadline).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(String(localized: "aiManager.action.edit"), systemImage: "pencil") { editBuffer = cfg; showEditSheet = true }
                        Button(String(localized: "aiManager.action.setActive"), systemImage: "checkmark.circle") { manager.select(cfg.id) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let idx = manager.providers.firstIndex(of: cfg) {
                                manager.remove(at: IndexSet(integer: idx))
                            }
                        } label: { Label(String(localized: "aiManager.action.delete"), systemImage: "trash") }
                    }
                }
            }
            .navigationTitle(Text("aiManager.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newProviderSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $newProviderSheet, onDismiss: {
                draft = AIProviderConfig(name: String(localized: "aiManager.placeholder.newProvider"), type: .openAI)
            }) {
                NavigationView {
                    AIEditor(config: $draft) { saved in
                        manager.add(saved)
                        newProviderSheet = false
                    }
                }
            }
            .sheet(isPresented: $showEditSheet) {
                NavigationView {
                    AIEditor(config: $editBuffer) { updated in
                        manager.update(updated)
                        showEditSheet = false
                    }
                }
            }
        }
    }
}
