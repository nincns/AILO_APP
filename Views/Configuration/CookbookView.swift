import SwiftUI

/// Hierarchical Cookbook Browser for Recipes
/// Shows list of cookbooks, then chapters/recipes within a cookbook
struct CookbookView: View {
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @State private var selectedCookbookID: UUID? = nil
    @State private var currentChapterID: UUID? = nil
    @State private var showNewCookbookSheet = false
    @State private var showNewChapterSheet = false
    @State private var showNewRecipeSheet = false
    @State private var editingCookbook: Cookbook? = nil
    @State private var editingRecipe: PrePromptRecipe? = nil
    @State private var editingChapter: RecipeMenuItem? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if selectedCookbookID == nil {
                    // Show list of cookbooks
                    cookbookListView
                } else {
                    // Show cookbook content
                    cookbookContentView
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
            .sheet(isPresented: $showNewCookbookSheet) {
                CookbookEditorSheet(
                    cookbook: nil,
                    onSave: { name, icon, keywords in
                        manager.createCookbook(name: name, icon: icon, keywords: keywords)
                    }
                )
            }
            .sheet(item: $editingCookbook) { cookbook in
                CookbookEditorSheet(
                    cookbook: cookbook,
                    onSave: { name, icon, keywords in
                        let updated = cookbook.updated(name: name, icon: icon, keywords: keywords)
                        manager.updateCookbook(updated)
                    }
                )
            }
            .sheet(isPresented: $showNewChapterSheet) {
                ChapterEditorSheet(
                    chapter: nil,
                    onSave: { name, icon, keywords in
                        if let cookbookID = selectedCookbookID {
                            manager.createChapter(name: name, icon: icon, keywords: keywords, in: cookbookID, parentID: currentChapterID)
                        }
                    }
                )
            }
            .sheet(isPresented: $showNewRecipeSheet) {
                RecipeEditorSheet(
                    recipe: nil,
                    onSave: { recipe in
                        if let cookbookID = selectedCookbookID {
                            manager.addRecipeInCookbook(recipe, in: cookbookID, parentID: currentChapterID)
                        }
                    }
                )
            }
            .sheet(item: $editingRecipe) { recipe in
                RecipeEditorSheet(
                    recipe: recipe,
                    onSave: { updated in
                        manager.updateRecipeInCookbook(updated)
                    }
                )
            }
            .sheet(item: $editingChapter) { chapter in
                ChapterEditorSheet(
                    chapter: chapter,
                    onSave: { name, icon, keywords in
                        var updated = chapter
                        updated.name = name
                        updated.icon = icon
                        updated.keywords = keywords
                        manager.updateRecipeMenuItem(updated)
                    }
                )
            }
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        if let cookbookID = selectedCookbookID {
            if let chapterID = currentChapterID,
               let chapter = manager.recipeMenuItem(withID: chapterID) {
                return chapter.name
            }
            if let cookbook = manager.cookbook(withID: cookbookID) {
                return cookbook.name
            }
        }
        return String(localized: "cookbook.title")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if selectedCookbookID != nil {
                Button {
                    navigateUp()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            if selectedCookbookID == nil {
                // Cookbook list: Add new cookbook
                Button {
                    showNewCookbookSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            } else {
                // Cookbook content: Add chapter or recipe
                Menu {
                    Button {
                        showNewChapterSheet = true
                    } label: {
                        Label(String(localized: "cookbook.chapter.new"), systemImage: "folder.badge.plus")
                    }

                    Button {
                        showNewRecipeSheet = true
                    } label: {
                        Label(String(localized: "cookbook.recipe.new"), systemImage: "book.closed.fill")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            EditButton()
        }
    }

    // MARK: - Cookbook List View

    private var cookbookListView: some View {
        List {
            if manager.cookbooks.isEmpty {
                cookbookEmptyState
            } else {
                ForEach(manager.cookbooks.sorted()) { cookbook in
                    cookbookRow(cookbook)
                }
                .onDelete(perform: deleteCookbooks)
                .onMove(perform: moveCookbooks)
            }
        }
    }

    private var cookbookEmptyState: some View {
        VStack(spacing: 16) {
            Text("📚")
                .font(.system(size: 48))

            Text("cookbook.list.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            Button {
                showNewCookbookSheet = true
            } label: {
                Label(String(localized: "cookbook.new"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func cookbookRow(_ cookbook: Cookbook) -> some View {
        Button {
            selectedCookbookID = cookbook.id
        } label: {
            HStack(spacing: 12) {
                Text(cookbook.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cookbook.name)
                        .foregroundStyle(.primary)

                    let recipeCount = manager.recipes(inCookbook: cookbook.id).count
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                manager.deleteCookbook(cookbook.id)
            } label: {
                Label("catalog.action.delete", systemImage: "trash")
            }

            Button {
                editingCookbook = cookbook
            } label: {
                Label("catalog.action.edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func deleteCookbooks(at offsets: IndexSet) {
        let sorted = manager.cookbooks.sorted()
        for index in offsets {
            manager.deleteCookbook(sorted[index].id)
        }
    }

    private func moveCookbooks(from source: IndexSet, to destination: Int) {
        manager.reorderCookbooks(from: source, to: destination)
    }

    // MARK: - Cookbook Content View

    private var cookbookContentView: some View {
        List {
            if let cookbookID = selectedCookbookID {
                let children = manager.recipeChildren(of: currentChapterID, in: cookbookID)
                if children.isEmpty {
                    contentEmptyState
                } else {
                    ForEach(children) { item in
                        if item.isChapter {
                            chapterRow(item)
                        } else {
                            recipeRow(item)
                        }
                    }
                    .onDelete(perform: deleteItems)
                    .onMove(perform: moveItems)
                }
            }
        }
    }

    private var contentEmptyState: some View {
        VStack(spacing: 16) {
            Text("📖")
                .font(.system(size: 48))

            Text("cookbook.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    showNewChapterSheet = true
                } label: {
                    Label(String(localized: "cookbook.chapter.new"), systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)

                Button {
                    showNewRecipeSheet = true
                } label: {
                    Label(String(localized: "cookbook.recipe.new"), systemImage: "book.closed.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func chapterRow(_ item: RecipeMenuItem) -> some View {
        Button {
            currentChapterID = item.id
        } label: {
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(.primary)

                    if !item.keywords.isEmpty {
                        Text(item.keywords)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let cookbookID = selectedCookbookID {
                    let childCount = manager.recipeChildren(of: item.id, in: cookbookID).count
                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                manager.deleteRecipeMenuItem(item.id)
            } label: {
                Label("catalog.action.delete", systemImage: "trash")
            }

            Button {
                editingChapter = item
            } label: {
                Label("catalog.action.edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func recipeRow(_ item: RecipeMenuItem) -> some View {
        Button {
            if let recipeID = item.recipeID,
               let recipe = manager.recipe(withID: recipeID) {
                editingRecipe = recipe
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

                    if let recipeID = item.recipeID,
                       let recipe = manager.recipe(withID: recipeID) {
                        let elementCount = recipe.elementIDs.count
                        Text(String(localized: "catalog.recipe.elements \(elementCount)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                if let recipeID = item.recipeID {
                    manager.deleteRecipeFromCookbook(recipeID)
                }
            } label: {
                Label("catalog.action.delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func navigateUp() {
        if currentChapterID != nil {
            // Navigate up within cookbook
            if let chapterID = currentChapterID,
               let chapter = manager.recipeMenuItem(withID: chapterID) {
                currentChapterID = chapter.parentID
            }
        } else {
            // Go back to cookbook list
            selectedCookbookID = nil
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        guard let cookbookID = selectedCookbookID else { return }
        let items = manager.recipeChildren(of: currentChapterID, in: cookbookID)
        for index in offsets {
            let item = items[index]
            if item.isChapter {
                manager.deleteRecipeMenuItem(item.id)
            } else if let recipeID = item.recipeID {
                manager.deleteRecipeFromCookbook(recipeID)
            }
        }
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        guard let cookbookID = selectedCookbookID else { return }
        manager.reorderRecipeItems(in: currentChapterID, cookbookID: cookbookID, from: source, to: destination)
    }
}

// MARK: - Cookbook Editor Sheet

private struct CookbookEditorSheet: View {
    let cookbook: Cookbook?
    let onSave: (String, String, String) -> Void  // name, icon, keywords

    @State private var name: String
    @State private var icon: String
    @State private var keywords: String
    @Environment(\.dismiss) private var dismiss

    init(cookbook: Cookbook?, onSave: @escaping (String, String, String) -> Void) {
        self.cookbook = cookbook
        self.onSave = onSave
        _name = State(initialValue: cookbook?.name ?? "")
        _icon = State(initialValue: cookbook?.icon ?? "📚")
        _keywords = State(initialValue: cookbook?.keywords ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(cookbook == nil ? "cookbook.new" : "cookbook.edit")
                .font(.headline)
                .padding(.top, 8)

            // Icon + Name
            HStack(spacing: 8) {
                TextField("📚", text: $icon)
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

                TextField(String(localized: "cookbook.name.placeholder"), text: $name)
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

// MARK: - Chapter Editor Sheet

private struct ChapterEditorSheet: View {
    let chapter: RecipeMenuItem?
    let onSave: (String, String, String) -> Void  // name, icon, keywords

    @State private var name: String
    @State private var icon: String
    @State private var keywords: String
    @Environment(\.dismiss) private var dismiss

    init(chapter: RecipeMenuItem?, onSave: @escaping (String, String, String) -> Void) {
        self.chapter = chapter
        self.onSave = onSave
        _name = State(initialValue: chapter?.name ?? "")
        _icon = State(initialValue: chapter?.icon ?? "📚")
        _keywords = State(initialValue: chapter?.keywords ?? "")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(chapter == nil ? "cookbook.chapter.new" : "cookbook.chapter.edit")
                .font(.headline)
                .padding(.top, 8)

            // Icon + Name
            HStack(spacing: 8) {
                TextField("📚", text: $icon)
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

                TextField(String(localized: "cookbook.chapter.name.placeholder"), text: $name)
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

// MARK: - Shared Components

/// Keyword Bubble Input (shared with PrePromptCatalogView)
struct KeywordBubbleInput: View {
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
                TextField(tags.isEmpty ? String(localized: "keywords.placeholder") : "", text: $inputText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 100)
                    .onChange(of: inputText) { _, newValue in
                        checkForSemicolon(newValue)
                    }
                    .onSubmit {
                        addCurrentTag()
                    }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

/// Keyword Bubble
struct KeywordBubble: View {
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

/// Flow Layout for tags
struct FlowLayout: Layout {
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

struct RecipeEditorSheet: View {
    let recipe: PrePromptRecipe?
    let onSave: (PrePromptRecipe) -> Void

    @State private var name: String
    @State private var icon: String
    @State private var keywords: String
    @State private var selectedElementIDs: [UUID]
    @State private var showElementPicker = false
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    init(recipe: PrePromptRecipe?, onSave: @escaping (PrePromptRecipe) -> Void) {
        self.recipe = recipe
        self.onSave = onSave
        _name = State(initialValue: recipe?.name ?? "")
        _icon = State(initialValue: recipe?.icon ?? "📖")
        _keywords = State(initialValue: recipe?.keywords ?? "")
        _selectedElementIDs = State(initialValue: recipe?.elementIDs ?? [])
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

                // Selected elements list
                List {
                    Section(header: HStack {
                        Text("catalog.recipe.ingredients")
                        Spacer()
                        Button {
                            showElementPicker = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }) {
                        if selectedElementIDs.isEmpty {
                            Text("catalog.recipe.empty")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        } else {
                            ForEach(selectedElementIDs, id: \.self) { elementID in
                                if let menuItem = manager.menuItem(withID: elementID) {
                                    selectedElementRow(menuItem)
                                }
                            }
                            .onDelete(perform: removeElements)
                            .onMove(perform: moveSelectedElements)
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
                                elementIDs: selectedElementIDs
                            )
                        } else {
                            newRecipe = PrePromptRecipe(
                                name: name,
                                icon: icon,
                                keywords: keywords,
                                elementIDs: selectedElementIDs
                            )
                        }
                        onSave(newRecipe)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showElementPicker) {
                RecipeElementPicker(selectedIDs: $selectedElementIDs)
            }
        }
    }

    private func selectedElementRow(_ menuItem: PrePromptMenuItem) -> some View {
        HStack(spacing: 12) {
            Text(menuItem.icon)
                .font(.title3)
                .frame(width: 32, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(menuItem.name)
                        .font(.subheadline)

                    // Type indicator
                    if menuItem.isFolder {
                        Text("catalog.recipe.type.category")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .clipShape(Capsule())
                    } else {
                        Text("catalog.recipe.type.item")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                if !menuItem.keywords.isEmpty {
                    Text(menuItem.keywords)
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
        if selectedElementIDs.isEmpty {
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
                        .lineLimit(15)
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

        for elementID in selectedElementIDs {
            if let menuItem = manager.menuItem(withID: elementID) {
                for pair in menuItem.keywordPairs {
                    if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                        result.append(pair)
                    }
                }

                if let presetID = menuItem.presetID,
                   let preset = manager.preset(withID: presetID) {
                    for pair in preset.keywordPairs {
                        if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                            result.append(pair)
                        }
                    }
                }
            }
        }

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
        var parts: [String] = []

        for elementID in selectedElementIDs {
            if let menuItem = manager.menuItem(withID: elementID) {
                if menuItem.isFolder {
                    var sectionParts: [String] = []
                    sectionParts.append("## \(menuItem.name)")

                    if !menuItem.keywords.isEmpty {
                        let contextLines = menuItem.keywordPairs.map { "**\($0.key):** \($0.value)" }
                        sectionParts.append(contentsOf: contextLines)
                    }

                    parts.append(sectionParts.joined(separator: "\n"))
                } else if let presetID = menuItem.presetID,
                          let preset = manager.preset(withID: presetID) {
                    parts.append(preset.text)
                }
            }
        }

        return parts.joined(separator: "\n\n")
    }

    private func removeElements(at offsets: IndexSet) {
        selectedElementIDs.remove(atOffsets: offsets)
    }

    private func moveSelectedElements(from source: IndexSet, to destination: Int) {
        selectedElementIDs.move(fromOffsets: source, toOffset: destination)
    }
}

// MARK: - Recipe Element Picker

struct RecipeElementPicker: View {
    @Binding var selectedIDs: [UUID]
    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var currentFolderID: UUID? = nil

    var body: some View {
        NavigationView {
            List {
                if currentFolderID != nil {
                    Button {
                        navigateUp()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                            Text("catalog.recipe.picker.back")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                let folders = manager.children(of: currentFolderID).filter { $0.isFolder }
                if !folders.isEmpty {
                    Section(header: Text("catalog.recipe.picker.categories")) {
                        ForEach(folders) { folder in
                            HStack {
                                Button {
                                    currentFolderID = folder.id
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(folder.icon)
                                            .font(.title2)
                                            .frame(width: 44, alignment: .leading)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder.name)
                                                .font(.body)
                                                .foregroundStyle(.primary)

                                            if !folder.keywords.isEmpty {
                                                Text(folder.keywords)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)

                                Button {
                                    if !selectedIDs.contains(folder.id) {
                                        selectedIDs.append(folder.id)
                                    }
                                    dismiss()
                                } label: {
                                    Image(systemName: selectedIDs.contains(folder.id)
                                          ? "checkmark.circle.fill"
                                          : "plus.circle")
                                        .foregroundStyle(selectedIDs.contains(folder.id) ? .green : .blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                let items = manager.children(of: currentFolderID).filter { $0.isPreset }
                if !items.isEmpty {
                    Section(header: Text("catalog.recipe.picker.items")) {
                        ForEach(items) { item in
                            Button {
                                if !selectedIDs.contains(item.id) {
                                    selectedIDs.append(item.id)
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(item.icon)
                                        .font(.title2)
                                        .frame(width: 44, alignment: .leading)

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

                                    if selectedIDs.contains(item.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if folders.isEmpty && items.isEmpty {
                    VStack(spacing: 8) {
                        Text("📭")
                            .font(.largeTitle)
                        Text("catalog.recipe.picker.empty")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle(Text("catalog.recipe.addelement"))
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

    private func navigateUp() {
        if let folderID = currentFolderID,
           let folder = manager.menuItem(withID: folderID) {
            currentFolderID = folder.parentID
        }
    }
}
