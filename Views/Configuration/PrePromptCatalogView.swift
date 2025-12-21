import SwiftUI

/// Hierarchical Pre-Prompt Catalog Browser
struct PrePromptCatalogView: View {
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @State private var currentFolderID: UUID? = nil
    @State private var showNewFolderSheet = false
    @State private var showNewPresetSheet = false
    @State private var showNewRecipeSheet = false
    @State private var editingPreset: AIPrePromptPreset? = nil
    @State private var editingFolder: PrePromptMenuItem? = nil
    @State private var editingRecipe: PrePromptRecipe? = nil
    @State private var newFolderName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Recipes section (only at root level)
                if currentFolderID == nil && !manager.recipes.isEmpty {
                    Section(header: Text("catalog.section.recipes")) {
                        ForEach(manager.recipes) { recipe in
                            recipeRow(recipe)
                        }
                        .onDelete(perform: deleteRecipes)
                    }
                }

                // Categories and items
                if manager.children(of: currentFolderID).isEmpty && (currentFolderID != nil || manager.recipes.isEmpty) {
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

                        Divider()

                        Button {
                            showNewRecipeSheet = true
                        } label: {
                            Label(String(localized: "catalog.recipe.new"), systemImage: "book.closed")
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
            .sheet(isPresented: $showNewRecipeSheet) {
                RecipeEditorSheet(
                    recipe: nil,
                    onSave: { recipe in
                        manager.addRecipe(recipe)
                    }
                )
            }
            .sheet(item: $editingRecipe) { recipe in
                RecipeEditorSheet(
                    recipe: recipe,
                    onSave: { updated in
                        manager.updateRecipe(updated)
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

    private func recipeRow(_ recipe: PrePromptRecipe) -> some View {
        Button {
            editingRecipe = recipe
        } label: {
            HStack(spacing: 12) {
                Text(recipe.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    let itemCount = recipe.itemIDs.count
                    Text(String(localized: "catalog.recipe.items \(itemCount)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                manager.deleteRecipe(recipe.id)
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

    private func deleteRecipes(at offsets: IndexSet) {
        for index in offsets {
            let recipe = manager.recipes[index]
            manager.deleteRecipe(recipe.id)
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
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.category.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            // Keywords
            KeywordBubbleInput(keywords: $keywords)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.secondary)

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
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "catalog.category.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            // Keywords
            KeywordBubbleInput(keywords: $keywords)
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
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: icon) { _, newValue in
                        if newValue.count > 3 {
                            icon = String(newValue.prefix(3))
                        }
                    }

                TextField(String(localized: "preprompts.field.name.placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
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
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                Button(String(localized: "catalog.action.cancel")) {
                    dismiss()
                }
                .foregroundStyle(.secondary)

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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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

// MARK: - Recipe Editor Sheet

private struct RecipeEditorSheet: View {
    let recipe: PrePromptRecipe?
    let onSave: (PrePromptRecipe) -> Void

    @State private var name: String
    @State private var icon: String
    @State private var keywords: String
    @State private var selectedItemIDs: [UUID]
    @State private var showItemPicker = false
    @State private var showPreview = false
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    init(recipe: PrePromptRecipe?, onSave: @escaping (PrePromptRecipe) -> Void) {
        self.recipe = recipe
        self.onSave = onSave
        _name = State(initialValue: recipe?.name ?? "")
        _icon = State(initialValue: recipe?.icon ?? "📖")
        _keywords = State(initialValue: recipe?.keywords ?? "")
        _selectedItemIDs = State(initialValue: recipe?.itemIDs ?? [])
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header info
                VStack(spacing: 12) {
                    // Icon + Name
                    HStack(spacing: 8) {
                        TextField("📖", text: $icon)
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

                        TextField(String(localized: "catalog.recipe.name.placeholder"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Keywords
                    KeywordBubbleInput(keywords: $keywords)
                }
                .padding()
                .background(Color(.systemGroupedBackground))

                Divider()

                // Selected items list
                List {
                    Section(header: HStack {
                        Text("catalog.recipe.ingredients")
                        Spacer()
                        Button {
                            showItemPicker = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }) {
                        if selectedItemIDs.isEmpty {
                            Text("catalog.recipe.empty")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(selectedItemIDs, id: \.self) { itemID in
                                if let preset = manager.preset(withID: itemID) {
                                    selectedItemRow(preset)
                                }
                            }
                            .onDelete(perform: removeItems)
                            .onMove(perform: moveSelectedItems)
                        }
                    }

                    // Preview section
                    Section(header: Text("catalog.recipe.preview")) {
                        previewContent
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(Text(recipe == nil ? "catalog.recipe.new" : "catalog.recipe.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "catalog.action.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "catalog.action.save")) {
                        let newRecipe: PrePromptRecipe
                        if let existing = recipe {
                            newRecipe = existing.updated(
                                name: name,
                                icon: icon,
                                keywords: keywords,
                                itemIDs: selectedItemIDs
                            )
                        } else {
                            newRecipe = PrePromptRecipe(
                                name: name,
                                icon: icon,
                                keywords: keywords,
                                itemIDs: selectedItemIDs
                            )
                        }
                        onSave(newRecipe)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showItemPicker) {
                RecipeItemPicker(
                    selectedIDs: $selectedItemIDs,
                    presets: manager.presets
                )
            }
        }
    }

    private func selectedItemRow(_ preset: AIPrePromptPreset) -> some View {
        HStack(spacing: 12) {
            Text(preset.icon)
                .font(.title3)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.subheadline)

                if !preset.keywords.isEmpty {
                    Text(preset.keywords)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if selectedItemIDs.isEmpty {
            Text("catalog.recipe.preview.empty")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // Combined keywords
                let allKeywords = collectAllKeywords()
                if !allKeywords.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("catalog.recipe.preview.keywords")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        FlowLayout(spacing: 4) {
                            ForEach(Array(allKeywords.enumerated()), id: \.offset) { _, pair in
                                Text("\(pair.key): \(pair.value)")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.orange.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                // Combined prompt text
                VStack(alignment: .leading, spacing: 4) {
                    Text("catalog.recipe.preview.prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(generatePromptPreview())
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(10)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func collectAllKeywords() -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []

        // From selected items
        for itemID in selectedItemIDs {
            if let preset = manager.preset(withID: itemID) {
                for pair in preset.keywordPairs {
                    if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                        result.append(pair)
                    }
                }
            }
        }

        // Recipe keywords override
        let recipeKeywords = keywords.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { part -> (key: String, value: String)? in
                let components = part.split(separator: ":", maxSplits: 1)
                if components.count == 2 {
                    return (
                        key: String(components[0]).trimmingCharacters(in: .whitespaces),
                        value: String(components[1]).trimmingCharacters(in: .whitespaces)
                    )
                }
                return nil
            }

        for pair in recipeKeywords {
            if let index = result.firstIndex(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                result[index] = pair
            } else {
                result.append(pair)
            }
        }

        return result
    }

    private func generatePromptPreview() -> String {
        let texts = selectedItemIDs.compactMap { id in
            manager.preset(withID: id)?.text
        }
        return texts.joined(separator: "\n\n")
    }

    private func removeItems(at offsets: IndexSet) {
        selectedItemIDs.remove(atOffsets: offsets)
    }

    private func moveSelectedItems(from source: IndexSet, to destination: Int) {
        selectedItemIDs.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Recipe Item Picker

private struct RecipeItemPicker: View {
    @Binding var selectedIDs: [UUID]
    let presets: [AIPrePromptPreset]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(presets) { preset in
                    Button {
                        if !selectedIDs.contains(preset.id) {
                            selectedIDs.append(preset.id)
                        }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text(preset.icon)
                                .font(.title2)
                                .frame(width: 44, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .font(.body)
                                    .foregroundStyle(.primary)

                                Text(preset.text.prefix(50) + (preset.text.count > 50 ? "..." : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if selectedIDs.contains(preset.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(Text("catalog.recipe.additem"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "catalog.action.cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
