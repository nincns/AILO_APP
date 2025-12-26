// Views/Shared/PrePromptCatalogPickerSheet.swift
import SwiftUI

/// Reusable Pre-Prompt Catalog Picker Sheet (uses Prompt Manager / Cookbooks)
/// Navigates through Cookbooks → Chapters → Recipes
struct PrePromptCatalogPickerSheet: View {
    @Binding var navigationPath: [UUID]
    let onSelectRecipe: (PrePromptRecipe) -> Void

    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    // Navigation state: nil = cookbook list, UUID = inside a cookbook or chapter
    private var currentCookbookID: UUID? {
        navigationPath.first
    }

    private var currentChapterID: UUID? {
        navigationPath.count > 1 ? navigationPath.last : nil
    }

    // Current title
    private var currentTitle: String {
        if let chapterID = currentChapterID,
           let chapter = manager.recipeMenuItem(withID: chapterID) {
            return chapter.name
        }
        if let cookbookID = currentCookbookID,
           let cookbook = manager.cookbook(withID: cookbookID) {
            return cookbook.name
        }
        return String(localized: "cookbook.title")
    }

    // Check if we can go back
    private var canGoBack: Bool {
        !navigationPath.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                // Back button row (if not at root)
                if canGoBack {
                    Button {
                        navigateBack()
                    } label: {
                        HStack(spacing: 8) {
                            Text("🔙")
                                .font(.body)
                            Text(String(localized: "catalog.recipe.picker.back"))
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(UIColor.systemBackground))
                }

                // Content based on navigation level
                if currentCookbookID == nil {
                    // Root level: Show cookbooks
                    cookbookListContent
                } else {
                    // Inside a cookbook: Show chapters and recipes
                    cookbookContent
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "common.cancel")) {
                        navigationPath.removeAll()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Cookbook List (Root Level)

    @ViewBuilder
    private var cookbookListContent: some View {
        if manager.cookbooks.isEmpty {
            VStack(spacing: 12) {
                Text("📚")
                    .font(.largeTitle)
                Text("cookbook.list.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        } else {
            ForEach(manager.cookbooks.sorted()) { cookbook in
                Button {
                    navigationPath.append(cookbook.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(cookbook.icon)
                            .font(.title2)
                            .frame(width: 36, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cookbook.name)
                                    .foregroundStyle(.primary)
                                Text("›")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            let recipeCount = manager.recipes(inCookbook: cookbook.id).count
                            Text(String(localized: "cookbook.recipes.count \(recipeCount)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Cookbook Content (Chapters & Recipes)

    @ViewBuilder
    private var cookbookContent: some View {
        let children = getSortedChildren()

        if children.isEmpty {
            VStack(spacing: 12) {
                Text("📭")
                    .font(.largeTitle)
                Text("cookbook.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        } else {
            ForEach(children, id: \.self) { child in
                switch child {
                case .chapter(let item):
                    chapterRow(item)
                case .recipe(let item, let recipe):
                    recipeRow(item, recipe: recipe)
                }
            }
        }
    }

    // Get sorted children: chapters first, then recipes
    private func getSortedChildren() -> [CookbookChild] {
        guard let cookbookID = currentCookbookID else { return [] }

        let items = manager.recipeChildren(of: currentChapterID, in: cookbookID)
        var result: [CookbookChild] = []

        // Separate chapters and recipes
        var chapters: [(RecipeMenuItem, Int)] = []
        var recipes: [(RecipeMenuItem, PrePromptRecipe, Int)] = []

        for (index, item) in items.enumerated() {
            if item.isChapter {
                chapters.append((item, index))
            } else if let recipeID = item.recipeID,
                      let recipe = manager.recipe(withID: recipeID) {
                recipes.append((item, recipe, index))
            }
        }

        // Chapters first (sorted by sortOrder)
        for (item, _) in chapters.sorted(by: { $0.0.sortOrder < $1.0.sortOrder }) {
            result.append(.chapter(item))
        }

        // Then recipes (sorted by sortOrder)
        for (item, recipe, _) in recipes.sorted(by: { $0.0.sortOrder < $1.0.sortOrder }) {
            result.append(.recipe(item, recipe))
        }

        return result
    }

    private func chapterRow(_ item: RecipeMenuItem) -> some View {
        Button {
            navigationPath.append(item.id)
        } label: {
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 36, alignment: .leading)

                HStack {
                    Text(item.name)
                        .foregroundStyle(.primary)
                    Text("›")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Child count badge
                if let cookbookID = currentCookbookID {
                    let childCount = manager.recipeChildren(of: item.id, in: cookbookID).count
                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func recipeRow(_ item: RecipeMenuItem, recipe: PrePromptRecipe) -> some View {
        Button {
            onSelectRecipe(recipe)
            navigationPath.removeAll()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(.primary)

                    // Show element count
                    let elementCount = recipe.elementIDs.count
                    Text(String(localized: "catalog.recipe.elements \(elementCount)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Return indicator - recipe can be selected
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }

    private func navigateBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    // Helper enum for sorted children
    private enum CookbookChild: Hashable {
        case chapter(RecipeMenuItem)
        case recipe(RecipeMenuItem, PrePromptRecipe)

        func hash(into hasher: inout Hasher) {
            switch self {
            case .chapter(let item):
                hasher.combine("chapter")
                hasher.combine(item.id)
            case .recipe(let item, _):
                hasher.combine("recipe")
                hasher.combine(item.id)
            }
        }

        static func == (lhs: CookbookChild, rhs: CookbookChild) -> Bool {
            switch (lhs, rhs) {
            case (.chapter(let a), .chapter(let b)):
                return a.id == b.id
            case (.recipe(let a, _), .recipe(let b, _)):
                return a.id == b.id
            default:
                return false
            }
        }
    }
}
