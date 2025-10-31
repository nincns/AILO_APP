import SwiftUI
import Foundation
struct PrePromptManager: View {
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AIPrePromptPreset] = []
    @State private var newName: String = ""
    @State private var newText: String = ""
    @State private var editing: AIPrePromptPreset? = nil

    var body: some View {
        List {
            Section(header: Text("preprompts.section.existing")) {
                if presets.isEmpty {
                    Text("preprompts.list.empty").foregroundStyle(.secondary)
                }
                ForEach(presets) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Button { editing = p } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                    }
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
            Section(header: Text("preprompts.section.new")) {
                TextField(String(localized: "preprompts.field.name.placeholder"), text: $newName)
                TextEditor(text: $newText).frame(minHeight: 120)
                Button {
                    add()
                } label: {
                    Label(String(localized: "preprompts.action.add"), systemImage: "plus")
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(Text("preprompts.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("preprompts.toolbar.done") { persist(); dismiss() } }
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { item in
            NavigationView {
                Form {
                    Section(header: Text("preprompts.field.name")) {
                        TextField(String(localized: "preprompts.field.name"), text: Binding(
                            get: { itemForID(item.id)?.name ?? "" },
                            set: { newVal in
                                if let idx = presets.firstIndex(where: { $0.id == item.id }) {
                                    presets[idx].name = newVal
                                    persist()
                                }
                            }
                        ))
                    }
                    Section(header: Text("preprompts.field.content")) {
                        TextEditor(text: Binding(
                            get: { itemForID(item.id)?.text ?? "" },
                            set: { newVal in
                                if let idx = presets.firstIndex(where: { $0.id == item.id }) {
                                    presets[idx].text = newVal
                                    persist()
                                }
                            }
                        )).frame(minHeight: 160)
                    }
                }
                .navigationTitle(Text("preprompts.editor.title"))
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("preprompts.toolbar.done") { editing = nil; persist() } }
                }
            }
        }
    }

    // MARK: helpers
    private func load() {
        if let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
           let arr = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) {
            presets = arr
        } else {
            presets = [
                AIPrePromptPreset(
                    name: String(localized: "preprompts.default.name"),
                    text: String(localized: "preprompts.default.text")
                )
            ]
            persist()
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: kAIPresetsKey)
        }
    }
    private func add() {
        let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !t.isEmpty else { return }
        presets.append(AIPrePromptPreset(name: n, text: t))
        newName = ""; newText = ""; persist()
    }
    private func delete(at offsets: IndexSet) { presets.remove(atOffsets: offsets); persist() }
    private func move(from s: IndexSet, to d: Int) { presets.move(fromOffsets: s, toOffset: d); persist() }
    private func itemForID(_ id: UUID) -> AIPrePromptPreset? { presets.first { $0.id == id } }
}
