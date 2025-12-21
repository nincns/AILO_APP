import SwiftUI

/// Hierarchical Pre-Prompt Catalog Browser
struct PrePromptCatalogView: View {
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @State private var currentFolderID: UUID? = nil
    @State private var showNewFolderSheet = false
    @State private var showNewPresetSheet = false
    @State private var editingPreset: AIPrePromptPreset? = nil
    @State private var editingFolder: PrePromptMenuItem? = nil
    @State private var newFolderName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if manager.children(of: currentFolderID).isEmpty {
                    emptyState
                } else {
                    ForEach(manager.children(of: currentFolderID)) { item in
                        if item.isFolder {
                            folderRow(item)
                        } else {
                            presetRow(item)
                        }
                    }
                    .onDelete(perform: deleteItems)
                    .onMove(perform: moveItems)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if currentFolderID != nil {
                        Button {
                            navigateUp()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showNewFolderSheet = true
                        } label: {
                            Label(String(localized: "catalog.folder.new"), systemImage: "folder.badge.plus")
                        }

                        Button {
                            showNewPresetSheet = true
                        } label: {
                            Label(String(localized: "catalog.prompt.new"), systemImage: "plus.circle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
            }
            .sheet(isPresented: $showNewFolderSheet) {
                NewFolderSheet(
                    parentID: currentFolderID,
                    onSave: { name, icon in
                        manager.createFolder(name: name, icon: icon, in: currentFolderID)
                    }
                )
            }
            .sheet(isPresented: $showNewPresetSheet) {
                PresetEditorSheet(
                    preset: nil,
                    onSave: { preset in
                        manager.addPreset(preset, in: currentFolderID)
                    }
                )
            }
            .sheet(item: $editingPreset) { preset in
                PresetEditorSheet(
                    preset: preset,
                    onSave: { updated in
                        manager.updatePreset(updated)
                    }
                )
            }
            .sheet(item: $editingFolder) { folder in
                FolderEditorSheet(
                    folder: folder,
                    onSave: { updated in
                        manager.updateMenuItem(updated)
                    }
                )
            }
        }
    }

    // MARK: - Views

    private var navigationTitle: String {
        if let folderID = currentFolderID,
           let folder = manager.menuItems.first(where: { $0.id == folderID }) {
            return folder.name
        }
        return String(localized: "catalog.title")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("catalog.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    showNewFolderSheet = true
                } label: {
                    Label(String(localized: "catalog.folder.new"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showNewPresetSheet = true
                } label: {
                    Label(String(localized: "catalog.prompt.new"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func folderRow(_ item: PrePromptMenuItem) -> some View {
        Button {
            currentFolderID = item.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(.blue)
                    .frame(width: 28)

                Text(item.name)
                    .foregroundStyle(.primary)

                Spacer()

                let childCount = manager.children(of: item.id).count
                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                manager.deleteMenuItem(item.id)
            } label: {
                Label("catalog.action.delete", systemImage: "trash")
            }

            Button {
                editingFolder = item
            } label: {
                Label("catalog.action.edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func presetRow(_ item: PrePromptMenuItem) -> some View {
        Button {
            if let presetID = item.presetID,
               let preset = manager.preset(withID: presetID) {
                editingPreset = preset
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let presetID = item.presetID,
                       let preset = manager.preset(withID: presetID) {
                        Text(preset.text.prefix(50) + (preset.text.count > 50 ? "..." : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let presetID = item.presetID,
                   let preset = manager.preset(withID: presetID),
                   preset.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let presetID = item.presetID {
                    manager.deletePreset(presetID)
                }
            } label: {
                Label("catalog.action.delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func navigateUp() {
        if let folderID = currentFolderID,
           let folder = manager.menuItems.first(where: { $0.id == folderID }) {
            currentFolderID = folder.parentID
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = manager.children(of: currentFolderID)
        for index in offsets {
            let item = items[index]
            if item.isFolder {
                manager.deleteMenuItem(item.id)
            } else if let presetID = item.presetID {
                manager.deletePreset(presetID)
            }
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        manager.reorderItems(in: currentFolderID, from: source, to: destination)
    }
}

// MARK: - New Folder Sheet

private struct NewFolderSheet: View {
    let parentID: UUID?
    let onSave: (String, String) -> Void

    @State private var name = ""
    @State private var icon = "folder"
    @Environment(\.dismiss) private var dismiss

    private let iconOptions = [
        "folder", "folder.fill", "star.fill", "heart.fill",
        "bookmark.fill", "flag.fill", "tag.fill", "pin.fill"
    ]

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("catalog.folder.name")) {
                    TextField(String(localized: "catalog.folder.name.placeholder"), text: $name)
                }

                Section(header: Text("catalog.folder.icon")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(iconOptions, id: \.self) { iconName in
                            Button {
                                icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(icon == iconName ? Color.blue.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(Text("catalog.folder.new"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "catalog.action.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "catalog.action.save")) {
                        onSave(name, icon)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Folder Editor Sheet

private struct FolderEditorSheet: View {
    let folder: PrePromptMenuItem
    let onSave: (PrePromptMenuItem) -> Void

    @State private var name: String
    @State private var icon: String
    @Environment(\.dismiss) private var dismiss

    private let iconOptions = [
        "folder", "folder.fill", "star.fill", "heart.fill",
        "bookmark.fill", "flag.fill", "tag.fill", "pin.fill",
        "envelope", "note.text", "text.bubble", "list.clipboard"
    ]

    init(folder: PrePromptMenuItem, onSave: @escaping (PrePromptMenuItem) -> Void) {
        self.folder = folder
        self.onSave = onSave
        _name = State(initialValue: folder.name)
        _icon = State(initialValue: folder.icon)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("catalog.folder.name")) {
                    TextField(String(localized: "catalog.folder.name.placeholder"), text: $name)
                }

                Section(header: Text("catalog.folder.icon")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(iconOptions, id: \.self) { iconName in
                            Button {
                                icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(icon == iconName ? Color.blue.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle(Text("catalog.folder.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "catalog.action.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "catalog.action.save")) {
                        var updated = folder
                        updated.name = name
                        updated.icon = icon
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Preset Editor Sheet

private struct PresetEditorSheet: View {
    let preset: AIPrePromptPreset?
    let onSave: (AIPrePromptPreset) -> Void

    @State private var name: String
    @State private var text: String
    @State private var icon: String
    @State private var isDefault: Bool
    @Environment(\.dismiss) private var dismiss

    private let iconOptions = [
        "text.bubble", "text.bubble.fill", "doc.text", "doc.text.fill",
        "list.clipboard", "pencil", "wand.and.stars", "sparkles"
    ]

    init(preset: AIPrePromptPreset?, onSave: @escaping (AIPrePromptPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "")
        _text = State(initialValue: preset?.text ?? "")
        _icon = State(initialValue: preset?.icon ?? "text.bubble")
        _isDefault = State(initialValue: preset?.isDefault ?? false)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("preprompts.field.name")) {
                    TextField(String(localized: "preprompts.field.name.placeholder"), text: $name)
                }

                Section(header: Text("catalog.folder.icon")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(iconOptions, id: \.self) { iconName in
                            Button {
                                icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(icon == iconName ? Color.blue.opacity(0.2) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section(header: Text("preprompts.field.content")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                }

                Section {
                    Toggle(String(localized: "preprompt.toggle.default"), isOn: $isDefault)
                }
            }
            .navigationTitle(Text(preset == nil ? "catalog.prompt.new" : "preprompts.editor.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "catalog.action.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "catalog.action.save")) {
                        let newPreset: AIPrePromptPreset
                        if let existing = preset {
                            newPreset = existing.updated(
                                name: name,
                                text: text,
                                icon: icon,
                                isDefault: isDefault
                            )
                        } else {
                            newPreset = AIPrePromptPreset(
                                name: name,
                                text: text,
                                icon: icon,
                                isDefault: isDefault
                            )
                        }
                        onSave(newPreset)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                             text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
