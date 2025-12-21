import Foundation
import Combine
import SwiftUI

/// Manager for hierarchical Pre-Prompt catalog
/// Handles menu structure (PrePromptMenuItem), content (AIPrePromptPreset), and recipes (PrePromptRecipe)
public final class PrePromptCatalogManager: ObservableObject {
    public static let shared = PrePromptCatalogManager()

    @Published public private(set) var menuItems: [PrePromptMenuItem] = []
    @Published public private(set) var presets: [AIPrePromptPreset] = []
    @Published public private(set) var recipes: [PrePromptRecipe] = []

    private init() {
        load()
    }

    // MARK: - Load & Save

    public func load() {
        loadMenuItems()
        loadPresets()
        loadRecipes()

        // Migration: If menu is empty but presets exist, create menu entries
        if menuItems.isEmpty && !presets.isEmpty {
            migrateFromLegacy()
        }

        // First install: Create default structure
        if menuItems.isEmpty && presets.isEmpty {
            createDefaultStructure()
        }
    }

    private func loadMenuItems() {
        guard let data = UserDefaults.standard.data(forKey: kPrePromptMenuKey),
              let items = try? JSONDecoder().decode([PrePromptMenuItem].self, from: data) else {
            menuItems = []
            return
        }
        menuItems = items
    }

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
              let items = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) else {
            presets = []
            return
        }
        presets = items
    }

    private func loadRecipes() {
        guard let data = UserDefaults.standard.data(forKey: kPrePromptRecipesKey),
              let items = try? JSONDecoder().decode([PrePromptRecipe].self, from: data) else {
            recipes = []
            return
        }
        recipes = items
    }

    public func save() {
        saveMenuItems()
        savePresets()
        saveRecipes()
    }

    private func saveMenuItems() {
        guard let data = try? JSONEncoder().encode(menuItems) else { return }
        UserDefaults.standard.set(data, forKey: kPrePromptMenuKey)
    }

    private func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: kAIPresetsKey)
    }

    private func saveRecipes() {
        guard let data = try? JSONEncoder().encode(recipes) else { return }
        UserDefaults.standard.set(data, forKey: kPrePromptRecipesKey)
    }

    // MARK: - Menu Item CRUD

    /// Add a new menu item (folder or preset reference)
    public func addMenuItem(_ item: PrePromptMenuItem) {
        menuItems.append(item)
        saveMenuItems()
    }

    /// Update an existing menu item
    public func updateMenuItem(_ item: PrePromptMenuItem) {
        guard let index = menuItems.firstIndex(where: { $0.id == item.id }) else { return }
        menuItems[index] = item
        saveMenuItems()
    }

    /// Delete a menu item and all its descendants
    public func deleteMenuItem(_ itemID: UUID) {
        // Get all descendant IDs
        let descendantIDs = menuItems.descendants(of: itemID)
        let allIDsToDelete = [itemID] + descendantIDs

        // Collect preset IDs to delete
        let presetIDsToDelete = allIDsToDelete.compactMap { id in
            menuItems.first(where: { $0.id == id })?.presetID
        }

        // Remove menu items
        menuItems.removeAll { allIDsToDelete.contains($0.id) }

        // Remove associated presets
        presets.removeAll { presetIDsToDelete.contains($0.id) }

        save()
    }

    /// Move a menu item to a new parent
    public func moveMenuItem(_ itemID: UUID, to newParentID: UUID?) {
        guard let index = menuItems.firstIndex(where: { $0.id == itemID }) else { return }
        menuItems[index].parentID = newParentID
        menuItems[index].sortOrder = menuItems.children(of: newParentID).count
        saveMenuItems()
    }

    /// Reorder items within a parent
    public func reorderItems(in parentID: UUID?, from source: IndexSet, to destination: Int) {
        var childrenList = menuItems.children(of: parentID)
        childrenList.move(fromOffsets: source, toOffset: destination)

        // Update sort orders
        for (index, child) in childrenList.enumerated() {
            if let menuIndex = menuItems.firstIndex(where: { $0.id == child.id }) {
                menuItems[menuIndex].sortOrder = index
            }
        }

        saveMenuItems()
    }

    // MARK: - Preset CRUD

    /// Add a new preset and create a menu item for it
    public func addPreset(_ preset: AIPrePromptPreset, in parentID: UUID?) {
        presets.append(preset)

        let menuItem = PrePromptMenuItem.preset(
            name: preset.name,
            icon: preset.icon,
            parentID: parentID,
            sortOrder: menuItems.children(of: parentID).count,
            presetID: preset.id
        )
        menuItems.append(menuItem)

        save()
    }

    /// Update an existing preset
    public func updatePreset(_ preset: AIPrePromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset

        // Also update the menu item name/icon
        if let menuIndex = menuItems.firstIndex(where: { $0.presetID == preset.id }) {
            menuItems[menuIndex].name = preset.name
            menuItems[menuIndex].icon = preset.icon
        }

        save()
    }

    /// Delete a preset and its menu item
    public func deletePreset(_ presetID: UUID) {
        presets.removeAll { $0.id == presetID }
        menuItems.removeAll { $0.presetID == presetID }
        save()
    }

    // MARK: - Folder Operations

    /// Create a new folder
    public func createFolder(name: String, icon: String = "📁", keywords: String = "", in parentID: UUID?) {
        let folder = PrePromptMenuItem.folder(
            name: name,
            icon: icon,
            keywords: keywords,
            parentID: parentID,
            sortOrder: menuItems.children(of: parentID).count
        )
        menuItems.append(folder)
        saveMenuItems()
    }

    /// Rename a folder
    public func renameFolder(_ folderID: UUID, to newName: String) {
        guard let index = menuItems.firstIndex(where: { $0.id == folderID }) else { return }
        menuItems[index].name = newName
        saveMenuItems()
    }

    // MARK: - Recipe CRUD

    /// Add a new recipe
    public func addRecipe(_ recipe: PrePromptRecipe) {
        recipes.append(recipe)
        saveRecipes()
    }

    /// Update an existing recipe
    public func updateRecipe(_ recipe: PrePromptRecipe) {
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        recipes[index] = recipe
        saveRecipes()
    }

    /// Delete a recipe
    public func deleteRecipe(_ recipeID: UUID) {
        recipes.removeAll { $0.id == recipeID }
        saveRecipes()
    }

    /// Get recipe by ID
    public func recipe(withID id: UUID) -> PrePromptRecipe? {
        recipes.first(where: { $0.id == id })
    }

    /// Generate complete prompt from a recipe
    public func generatePrompt(from recipe: PrePromptRecipe) -> String {
        recipe.generatePrompt(from: presets)
    }

    /// Get all keywords from a recipe (including referenced items)
    public func collectKeywords(from recipe: PrePromptRecipe) -> [(key: String, value: String)] {
        recipe.collectKeywords(from: presets)
    }

    // MARK: - Query Helpers

    /// Get children of a parent (nil = root)
    public func children(of parentID: UUID?) -> [PrePromptMenuItem] {
        menuItems.children(of: parentID)
    }

    /// Get breadcrumb path to an item
    public func path(to itemID: UUID) -> [PrePromptMenuItem] {
        menuItems.path(to: itemID)
    }

    /// Get preset by ID
    public func preset(withID id: UUID) -> AIPrePromptPreset? {
        presets.first(where: { $0.id == id })
    }

    /// Get all presets in a folder (recursively)
    public func presets(in folderID: UUID?) -> [AIPrePromptPreset] {
        let presetIDs = menuItems.presetIDs(in: folderID)
        return presetIDs.compactMap { id in
            presets.first(where: { $0.id == id })
        }
    }

    // MARK: - Migration

    /// Migrate from legacy flat preset list
    private func migrateFromLegacy() {
        // Create root category "Migriert"
        let migratedFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.migrated"),
            icon: "📤",
            parentID: nil,
            sortOrder: 0
        )
        menuItems.append(migratedFolder)

        // Create menu items for each existing preset
        for (index, preset) in presets.enumerated() {
            let menuItem = PrePromptMenuItem.preset(
                name: preset.name,
                icon: preset.icon,
                parentID: migratedFolder.id,
                sortOrder: index,
                presetID: preset.id
            )
            menuItems.append(menuItem)
        }

        saveMenuItems()
    }

    // MARK: - Default Structure

    /// Create default category structure for new installations
    private func createDefaultStructure() {
        // Mail category
        let mailFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.mail"),
            icon: "📧",
            parentID: nil,
            sortOrder: 0
        )
        menuItems.append(mailFolder)

        // Mail subcategories
        let replyFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.reply"),
            icon: "↩️",
            parentID: mailFolder.id,
            sortOrder: 0
        )
        menuItems.append(replyFolder)

        let forwardFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.forward"),
            icon: "↪️",
            parentID: mailFolder.id,
            sortOrder: 1
        )
        menuItems.append(forwardFolder)

        let analyzeFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.analyze"),
            icon: "🔍",
            parentID: mailFolder.id,
            sortOrder: 2
        )
        menuItems.append(analyzeFolder)

        // Notes category
        let notesFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.notes"),
            icon: "📝",
            parentID: nil,
            sortOrder: 1
        )
        menuItems.append(notesFolder)

        // Default protocol preset
        let protocolPreset = AIPrePromptPreset(
            name: String(localized: "preprompts.default.name"),
            text: String(localized: "preprompts.default.text"),
            icon: "📋",
            isDefault: true
        )
        presets.append(protocolPreset)

        let protocolMenuItem = PrePromptMenuItem.preset(
            name: protocolPreset.name,
            icon: protocolPreset.icon,
            parentID: notesFolder.id,
            sortOrder: 0,
            presetID: protocolPreset.id
        )
        menuItems.append(protocolMenuItem)

        // General category
        let generalFolder = PrePromptMenuItem.folder(
            name: String(localized: "catalog.category.general"),
            icon: "💬",
            parentID: nil,
            sortOrder: 2
        )
        menuItems.append(generalFolder)

        save()
    }
}

// MARK: - Convenience Functions

/// Load presets using the catalog manager
public func loadPrePromptPresets() -> [AIPrePromptPreset] {
    return PrePromptCatalogManager.shared.presets
}
