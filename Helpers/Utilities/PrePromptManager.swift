import SwiftUI
import Foundation

struct PrePromptManager: View {
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [AIPrePromptPreset] = []
    @State private var newName: String = ""
    @State private var newText: String = ""
    @State private var newCategory: PrePromptCategory = .general
    @State private var newContext: PrePromptContext = .general
    @State private var editing: AIPrePromptPreset? = nil

    var body: some View {
        List {
            // Grouped by category
            ForEach(PrePromptCategory.allCases, id: \.self) { category in
                let categoryPresets = presets.filter { $0.category == category }
                if !categoryPresets.isEmpty {
                    Section(header: categoryHeader(category)) {
                        ForEach(categoryPresets.sorted { $0.sortOrder < $1.sortOrder }) { preset in
                            presetRow(preset)
                        }
                        .onDelete { offsets in
                            deleteInCategory(category, at: offsets)
                        }
                    }
                }
            }

            // Add new preset section
            Section(header: Text("preprompts.section.new")) {
                TextField(String(localized: "preprompts.field.name.placeholder"), text: $newName)

                // Category picker
                Picker(String(localized: "preprompt.picker.category"), selection: $newCategory) {
                    ForEach(PrePromptCategory.allCases, id: \.self) { cat in
                        Label(cat.localizedName, systemImage: cat.icon).tag(cat)
                    }
                }
                .onChange(of: newCategory) { _, newCat in
                    // Reset context when category changes
                    newContext = newCat.contexts.first ?? .general
                }

                // Context picker (filtered by category)
                Picker(String(localized: "preprompt.picker.context"), selection: $newContext) {
                    ForEach(newCategory.contexts, id: \.self) { ctx in
                        Label(ctx.localizedName, systemImage: ctx.icon).tag(ctx)
                    }
                }

                TextEditor(text: $newText)
                    .frame(minHeight: 120)

                Button {
                    add()
                } label: {
                    Label(String(localized: "preprompts.action.add"), systemImage: "plus")
                }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(Text("preprompts.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("preprompts.toolbar.done") {
                    persist()
                    dismiss()
                }
            }
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { item in
            NavigationView {
                PrePromptEditSheet(
                    preset: bindingForPreset(item.id),
                    onSave: { persist() },
                    onDismiss: { editing = nil }
                )
            }
        }
    }

    // MARK: - Views

    private func categoryHeader(_ category: PrePromptCategory) -> some View {
        Label(category.localizedName, systemImage: category.icon)
    }

    private func presetRow(_ preset: AIPrePromptPreset) -> some View {
        HStack(spacing: 12) {
            Image(systemName: preset.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                Text(preset.context.localizedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if preset.isDefault {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }

            Button {
                editing = preset
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Helpers

    private func load() {
        if let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
           let arr = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) {
            presets = arr
        } else {
            // Default presets for new installations
            presets = [
                AIPrePromptPreset(
                    name: String(localized: "preprompts.default.name"),
                    text: String(localized: "preprompts.default.text"),
                    category: .general,
                    context: .general,
                    isDefault: true
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

        let newPreset = AIPrePromptPreset(
            name: n,
            text: t,
            category: newCategory,
            context: newContext,
            sortOrder: presets.filter { $0.category == newCategory }.count
        )
        presets.append(newPreset)
        newName = ""
        newText = ""
        persist()
    }

    private func deleteInCategory(_ category: PrePromptCategory, at offsets: IndexSet) {
        let categoryPresets = presets.filter { $0.category == category }
            .sorted { $0.sortOrder < $1.sortOrder }
        let idsToDelete = offsets.map { categoryPresets[$0].id }
        presets.removeAll { idsToDelete.contains($0.id) }
        persist()
    }

    private func bindingForPreset(_ id: UUID) -> Binding<AIPrePromptPreset> {
        Binding(
            get: {
                presets.first { $0.id == id } ?? AIPrePromptPreset(name: "", text: "")
            },
            set: { newValue in
                if let idx = presets.firstIndex(where: { $0.id == id }) {
                    presets[idx] = newValue
                }
            }
        )
    }
}

// MARK: - Edit Sheet

private struct PrePromptEditSheet: View {
    @Binding var preset: AIPrePromptPreset
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Form {
            Section(header: Text("preprompts.field.name")) {
                TextField(String(localized: "preprompts.field.name"), text: $preset.name)
            }

            Section(header: Text("preprompt.picker.category")) {
                Picker(String(localized: "preprompt.picker.category"), selection: $preset.category) {
                    ForEach(PrePromptCategory.allCases, id: \.self) { cat in
                        Label(cat.localizedName, systemImage: cat.icon).tag(cat)
                    }
                }
                .onChange(of: preset.category) { _, newCat in
                    // Reset context when category changes
                    if !newCat.contexts.contains(preset.context) {
                        preset.context = newCat.contexts.first ?? .general
                    }
                    preset.icon = preset.context.icon
                }

                Picker(String(localized: "preprompt.picker.context"), selection: $preset.context) {
                    ForEach(preset.category.contexts, id: \.self) { ctx in
                        Label(ctx.localizedName, systemImage: ctx.icon).tag(ctx)
                    }
                }
                .onChange(of: preset.context) { _, newCtx in
                    preset.icon = newCtx.icon
                }
            }

            Section(header: Text("preprompts.field.content")) {
                TextEditor(text: $preset.text)
                    .frame(minHeight: 160)
            }

            Section {
                Toggle(String(localized: "preprompt.toggle.default"), isOn: $preset.isDefault)
            }
        }
        .navigationTitle(Text("preprompts.editor.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("preprompts.toolbar.done") {
                    onSave()
                    onDismiss()
                }
            }
        }
    }
}
