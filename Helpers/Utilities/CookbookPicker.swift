import SwiftUI
import Foundation

/// Picker for selecting a Cookbook (Prompt Manager)
/// Shows only cookbooks, generates combined prompt from all recipes in the cookbook
struct CookbookPicker: View {
    var onSelect: ((Cookbook, String) -> Void)?  // Returns cookbook and generated prompt

    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if manager.cookbooks.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.cookbooks.sorted()) { cookbook in
                        cookbookRow(cookbook)
                    }
                }
            }
            .navigationTitle(Text("cookbook.picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Views

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("📚")
                .font(.system(size: 48))

            Text("cookbook.picker.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("cookbook.picker.empty.hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func cookbookRow(_ cookbook: Cookbook) -> some View {
        Button {
            selectCookbook(cookbook)
        } label: {
            HStack(spacing: 12) {
                Text(cookbook.icon)
                    .font(.title2)
                    .frame(width: 44, alignment: .leading)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cookbook.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    let recipeCount = manager.recipes(inCookbook: cookbook.id).count
                    if recipeCount > 0 {
                        Text(String(localized: "cookbook.recipes.count \(recipeCount)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func selectCookbook(_ cookbook: Cookbook) {
        // Generate combined prompt from all recipes in the cookbook
        let prompt = generatePrompt(for: cookbook)
        onSelect?(cookbook, prompt)
        dismiss()
    }

    /// Generate combined prompt from all recipes in a cookbook
    private func generatePrompt(for cookbook: Cookbook) -> String {
        let recipes = manager.recipes(inCookbook: cookbook.id)

        if recipes.isEmpty {
            // Fallback: use cookbook keywords if no recipes
            return cookbook.keywords
        }

        // Combine all recipe prompts
        var prompts: [String] = []

        for recipe in recipes {
            let recipePrompt = manager.generatePrompt(from: recipe)
            if !recipePrompt.isEmpty {
                prompts.append(recipePrompt)
            }
        }

        // If no prompts from recipes, use keywords
        if prompts.isEmpty {
            // Build prompt from cookbook + recipe keywords
            var keywordParts: [String] = []

            // Cookbook keywords
            for pair in cookbook.keywordPairs {
                keywordParts.append("\(pair.key): \(pair.value)")
            }

            // Recipe keywords
            for recipe in recipes {
                for pair in recipe.keywordPairs {
                    keywordParts.append("\(pair.key): \(pair.value)")
                }
            }

            return keywordParts.joined(separator: "\n")
        }

        return prompts.joined(separator: "\n\n---\n\n")
    }
}

// MARK: - Convenience Modifier

extension View {
    /// Shows a cookbook picker sheet
    func cookbookPicker(
        isPresented: Binding<Bool>,
        onSelect: @escaping (Cookbook, String) -> Void
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            CookbookPicker(onSelect: onSelect)
        }
    }
}
