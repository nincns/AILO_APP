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
            Text("📁")
                .font(.system(size: 48))

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
                Text(item.icon)
                    .font(.title2)
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
                Text(item.icon)
                    .font(.title2)
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

// MARK: - New Folder Popup

private struct NewFolderSheet: View {
    let parentID: UUID?
    let onSave: (String, String) -> Void

    @State private var name = ""
    @State private var icon = "📁"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("catalog.folder.new")
                .font(.headline)
                .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("📁", text: $icon)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.folder.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.secondary)

                Button(String(localized: "catalog.action.save")) {
                    onSave(name, icon)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .presentationDetents([.height(160)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Folder Editor Popup

private struct FolderEditorSheet: View {
    let folder: PrePromptMenuItem
    let onSave: (PrePromptMenuItem) -> Void

    @State private var name: String
    @State private var icon: String
    @Environment(\.dismiss) private var dismiss

    init(folder: PrePromptMenuItem, onSave: @escaping (PrePromptMenuItem) -> Void) {
        self.folder = folder
        self.onSave = onSave
        _name = State(initialValue: folder.name)
        _icon = State(initialValue: folder.icon)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("catalog.folder.edit")
                .font(.headline)
                .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("📁", text: $icon)
                    .frame(width: 50)
                    .multilineTextAlignment(.center)
                    .font(.title2)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.folder.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.secondary)

                Button(String(localized: "catalog.action.save")) {
                    var updated = folder
                    updated.name = name
                    updated.icon = icon
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.bottom, 8)
        }
        .padding()
        .presentationDetents([.height(160)])
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
    @State private var isDefault: Bool
    @Environment(\.dismiss) private var dismiss

    init(preset: AIPrePromptPreset?, onSave: @escaping (AIPrePromptPreset) -> Void) {
        self.preset = preset
        self.onSave = onSave
        _name = State(initialValue: preset?.name ?? "")
        _text = State(initialValue: preset?.text ?? "")
        _icon = State(initialValue: preset?.icon ?? "💬")
        _keywords = State(initialValue: preset?.keywords ?? "")
        _isDefault = State(initialValue: preset?.isDefault ?? false)
    }

    var body: some View {
        NavigationView {
            Form {
                // Symbol + Name in einer Zeile
                Section(header: Text("preprompts.field.name")) {
                    HStack(spacing: 8) {
                        TextField("💬", text: $icon)
                            .frame(width: 50)
                            .multilineTextAlignment(.center)
                            .font(.title2)
                            .onChange(of: icon) { _, newValue in
                                // Max 3 Zeichen
                                if newValue.count > 3 {
                                    icon = String(newValue.prefix(3))
                                }
                            }

                        TextField(String(localized: "preprompts.field.name.placeholder"), text: $name)
                    }
                }

                // Schlagwörter/Metadaten
                Section(header: Text("preprompts.field.keywords")) {
                    KeywordBubbleInput(keywords: $keywords)
                        .padding(.vertical, 4)
                }

                // Prompt-Inhalt
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
                                keywords: keywords,
                                isDefault: isDefault
                            )
                        } else {
                            newPreset = AIPrePromptPreset(
                                name: name,
                                text: text,
                                icon: icon,
                                keywords: keywords,
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

// MARK: - Keyword Bubble Input

private struct KeywordBubbleInput: View {
    @Binding var keywords: String

    @State private var inputText = ""
    @State private var tags: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bubbles in FlowLayout
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                    KeywordBubble(text: tag) {
                        removeTag(at: index)
                    }
                }

                // Eingabefeld
                TextField(tags.isEmpty ? String(localized: "preprompts.field.keywords.placeholder") : "", text: $inputText)
                    .font(.subheadline)
                    .frame(minWidth: 100)
                    .onChange(of: inputText) { _, newValue in
                        checkForSemicolon(newValue)
                    }
                    .onSubmit {
                        addCurrentTag()
                    }
            }
        }
        .onAppear {
            parseTags()
        }
    }

    private func parseTags() {
        tags = keywords.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func checkForSemicolon(_ text: String) {
        if text.contains(";") {
            let parts = text.split(separator: ";", omittingEmptySubsequences: false)
            for part in parts.dropLast() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    tags.append(trimmed)
                }
            }
            inputText = String(parts.last ?? "").trimmingCharacters(in: .whitespaces)
            updateKeywords()
        }
    }

    private func addCurrentTag() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            tags.append(trimmed)
            inputText = ""
            updateKeywords()
        }
    }

    private func removeTag(at index: Int) {
        guard index < tags.count else { return }
        tags.remove(at: index)
        updateKeywords()
    }

    private func updateKeywords() {
        keywords = tags.joined(separator: "; ")
    }
}

// MARK: - Keyword Bubble

private struct KeywordBubble: View {
    let text: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.subheadline)
                .lineLimit(1)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.blue.opacity(0.15))
        .foregroundStyle(.primary)
        .clipShape(Capsule())
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Neue Zeile
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))

            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        totalHeight = currentY + lineHeight

        return (CGSize(width: totalWidth, height: totalHeight), frames)
    }
}
