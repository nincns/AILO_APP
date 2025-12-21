import SwiftUI
import UniformTypeIdentifiers

/// Hierarchical Pre-Prompt Catalog Browser
struct PrePromptCatalogView: View {
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @State private var currentFolderID: UUID? = nil
    @State private var showNewFolderSheet = false
    @State private var showNewPresetSheet = false
    @State private var showCookbook = false
    @State private var editingPreset: AIPrePromptPreset? = nil
    @State private var editingFolder: PrePromptMenuItem? = nil
    @State private var newFolderName = ""
    @State private var showImportPicker = false
    @State private var showExportShare = false
    @State private var exportURL: URL? = nil
    @State private var showImportAlert = false
    @State private var importAlertMessage = ""
    @State private var importAlertSuccess = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Cookbook link (only at root level)
                if currentFolderID == nil {
                    Section {
                        Button {
                            showCookbook = true
                        } label: {
                            HStack(spacing: 12) {
                                Text("📚")
                                    .font(.title2)
                                    .frame(width: 44, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("cookbook.title")
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    let recipeCount = manager.recipes.count
                                    Text(String(localized: "cookbook.recipes.count \(recipeCount)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Categories and items
                if manager.children(of: currentFolderID).isEmpty && currentFolderID != nil {
                    emptyState
                } else if !manager.children(of: currentFolderID).isEmpty {
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
                            Label(String(localized: "catalog.category.new"), systemImage: "folder.badge.plus")
                        }

                        Button {
                            showNewPresetSheet = true
                        } label: {
                            Label(String(localized: "catalog.item.new"), systemImage: "plus.circle")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }

                // Export/Import menu (only at root level)
                if currentFolderID == nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                exportCatalog()
                            } label: {
                                Label(String(localized: "catalog.action.export"), systemImage: "square.and.arrow.up")
                            }

                            Button {
                                showImportPicker = true
                            } label: {
                                Label(String(localized: "catalog.action.import"), systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.json],
                onCompletion: handleImport
            )
            .sheet(isPresented: $showExportShare) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
            .alert(
                importAlertSuccess ? String(localized: "catalog.import.success") : String(localized: "catalog.import.error"),
                isPresented: $showImportAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importAlertMessage)
            }
            .sheet(isPresented: $showNewFolderSheet) {
                NewFolderSheet(
                    parentID: currentFolderID,
                    onSave: { name, icon, keywords in
                        manager.createFolder(name: name, icon: icon, keywords: keywords, in: currentFolderID)
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
            .sheet(isPresented: $showCookbook) {
                CookbookView()
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
            Text("📁")
                .font(.system(size: 48))

            Text("catalog.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    showNewFolderSheet = true
                } label: {
                    Label(String(localized: "catalog.category.new"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showNewPresetSheet = true
                } label: {
                    Label(String(localized: "catalog.item.new"), systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
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
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

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
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

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

    // MARK: - Export/Import

    private func exportCatalog() {
        guard let data = manager.exportCatalog() else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let filename = manager.exportFilename()
        let fileURL = tempDir.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
            exportURL = fileURL
            showExportShare = true
        } catch {
            importAlertSuccess = false
            importAlertMessage = error.localizedDescription
            showImportAlert = true
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                importAlertSuccess = false
                importAlertMessage = String(localized: "catalog.import.access.error")
                showImportAlert = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                try manager.importCatalog(from: data)
                importAlertSuccess = true
                importAlertMessage = String(localized: "catalog.import.success.message")
                showImportAlert = true
            } catch {
                importAlertSuccess = false
                importAlertMessage = error.localizedDescription
                showImportAlert = true
            }

        case .failure(let error):
            importAlertSuccess = false
            importAlertMessage = error.localizedDescription
            showImportAlert = true
        }
    }
}

// MARK: - New Folder Popup

private struct NewFolderSheet: View {
    let parentID: UUID?
    let onSave: (String, String, String) -> Void  // name, icon, keywords

    @State private var name = ""
    @State private var icon = "📁"
    @State private var keywords = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("catalog.category.new")
                .font(.headline)
                .padding(.top, 8)

            // Icon + Name
            HStack(spacing: 8) {
                TextField("📁", text: $icon)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.category.name.placeholder"), text: $name)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)

            // Keywords
            KeywordBubbleInput(keywords: $keywords)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.red)

                Button(String(localized: "catalog.action.save")) {
                    onSave(name, icon, keywords)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Folder Editor Popup

private struct FolderEditorSheet: View {
    let folder: PrePromptMenuItem
    let onSave: (PrePromptMenuItem) -> Void

    @State private var name: String
    @State private var icon: String
    @State private var keywords: String
    @Environment(\.dismiss) private var dismiss

    init(folder: PrePromptMenuItem, onSave: @escaping (PrePromptMenuItem) -> Void) {
        self.folder = folder
        self.onSave = onSave
        _name = State(initialValue: folder.name)
        _icon = State(initialValue: folder.icon)
        _keywords = State(initialValue: folder.keywords)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("catalog.category.edit")
                .font(.headline)
                .padding(.top, 8)

            // Icon + Name
            HStack(spacing: 8) {
                TextField("📁", text: $icon)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.category.name.placeholder"), text: $name)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)

            // Keywords
            KeywordBubbleInput(keywords: $keywords)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.red)

                Button(String(localized: "catalog.action.save")) {
                    var updated = folder
                    updated.name = name
                    updated.icon = icon
                    updated.keywords = keywords
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Preset Editor Sheet

private struct PresetEditorSheet: View {
    let preset: AIPrePromptPreset?
    let onSave: (AIPrePromptPreset) -> Void

    @State private var name: String
    @State private var text: String
    @State private var icon: String
    @State private var keywords: String
    @Environment(\.dismiss) private var dismiss

    init(preset: AIPrePromptPreset?, onSave: @escaping (AIPrePromptPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "")
        _text = State(initialValue: preset?.text ?? "")
        _icon = State(initialValue: preset?.icon ?? "💬")
        _keywords = State(initialValue: preset?.keywords ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(preset == nil ? "catalog.item.new" : "preprompts.editor.title")
                .font(.headline)
                .padding(.top, 8)

            // Icon + Name
            HStack(spacing: 8) {
                TextField("💬", text: $icon)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "preprompts.field.name.placeholder"), text: $name)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)

            // Keywords
            KeywordBubbleInput(keywords: $keywords)
                .padding(.horizontal)

            // Prompt content
            VStack(alignment: .leading, spacing: 4) {
                Text("preprompts.field.content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                TextEditor(text: $text)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.red)

                Button(String(localized: "catalog.action.save")) {
                    let newPreset: AIPrePromptPreset
                    if let existing = preset {
                        newPreset = existing.updated(
                            name: name,
                            text: text,
                            icon: icon,
                            keywords: keywords
                        )
                    } else {
                        newPreset = AIPrePromptPreset(
                            name: name,
                            text: text,
                            icon: icon,
                            keywords: keywords
                        )
                    }
                    onSave(newPreset)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                         text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
