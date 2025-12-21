import Foundation

/// Hierarchisches Menü-Item für Rezept/Kochbuch Navigation
/// Kann entweder ein Kapitel (Ordner) oder ein Rezept-Verweis sein
public struct RecipeMenuItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var cookbookID: UUID                 // Zugehöriges Kochbuch
    public var parentID: UUID?                  // nil = Root-Level im Kochbuch
    public var name: String                     // Anzeigename im Menü
    public var icon: String                     // Emoji
    public var keywords: String                 // Semikolon-getrennte Schlagwörter (Metadaten)
    public var sortOrder: Int

    // Wenn recipeID gesetzt → Blatt-Element (verweist auf Rezept)
    // Wenn nil → Kapitel/Ordner
    public var recipeID: UUID?

    public var isChapter: Bool { recipeID == nil }
    public var isRecipe: Bool { recipeID != nil }

    // Full initializer
    public init(
        id: UUID = UUID(),
        cookbookID: UUID,
        parentID: UUID? = nil,
        name: String,
        icon: String = "📁",
        keywords: String = "",
        sortOrder: Int = 0,
        recipeID: UUID? = nil
    ) {
        self.id = id
        self.cookbookID = cookbookID
        self.parentID = parentID
        self.name = name
        self.icon = icon
        self.keywords = keywords
        self.sortOrder = sortOrder
        self.recipeID = recipeID
    }

    // Custom decoding for migration from old format (without cookbookID)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Migration: If no cookbookID, use a default UUID (will be fixed during migration)
        cookbookID = try container.decodeIfPresent(UUID.self, forKey: .cookbookID) ?? UUID()
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "📁"
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        recipeID = try container.decodeIfPresent(UUID.self, forKey: .recipeID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, cookbookID, parentID, name, icon, keywords, sortOrder, recipeID
    }

    /// Convenience initializer for chapter/folder
    public static func chapter(
        cookbookID: UUID,
        name: String,
        icon: String = "📚",
        keywords: String = "",
        parentID: UUID? = nil,
        sortOrder: Int = 0
    ) -> RecipeMenuItem {
        RecipeMenuItem(
            cookbookID: cookbookID,
            parentID: parentID,
            name: name,
            icon: icon,
            keywords: keywords,
            sortOrder: sortOrder,
            recipeID: nil
        )
    }

    /// Convenience initializer for recipe reference
    public static func recipe(
        cookbookID: UUID,
        name: String,
        icon: String = "📖",
        keywords: String = "",
        parentID: UUID? = nil,
        sortOrder: Int = 0,
        recipeID: UUID
    ) -> RecipeMenuItem {
        RecipeMenuItem(
            cookbookID: cookbookID,
            parentID: parentID,
            name: name,
            icon: icon,
            keywords: keywords,
            sortOrder: sortOrder,
            recipeID: recipeID
        )
    }

    /// Parse keywords into key-value pairs
    public var keywordPairs: [(key: String, value: String)] {
        keywords.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { part in
                let components = part.split(separator: ":", maxSplits: 1)
                if components.count == 2 {
                    return (
                        key: String(components[0]).trimmingCharacters(in: .whitespaces),
                        value: String(components[1]).trimmingCharacters(in: .whitespaces)
                    )
                }
                return nil
            }
    }

    /// Get value for a specific keyword key
    public func keyword(_ key: String) -> String? {
        keywordPairs.first { $0.key.lowercased() == key.lowercased() }?.value
    }
}

// MARK: - Array Extensions

extension Array where Element == RecipeMenuItem {
    /// Returns all items in a specific cookbook
    func items(in cookbookID: UUID) -> [RecipeMenuItem] {
        filter { $0.cookbookID == cookbookID }
    }

    /// Returns children of the given parent in a specific cookbook (nil = root level)
    func children(of parentID: UUID?, in cookbookID: UUID) -> [RecipeMenuItem] {
        filter { $0.cookbookID == cookbookID && $0.parentID == parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns children of the given parent (nil = root level) - legacy support
    func children(of parentID: UUID?) -> [RecipeMenuItem] {
        filter { $0.parentID == parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns the path from root to the given item (breadcrumb)
    func path(to itemID: UUID) -> [RecipeMenuItem] {
        guard let item = first(where: { $0.id == itemID }) else { return [] }

        var path: [RecipeMenuItem] = [item]
        var current = item

        while let parentID = current.parentID,
              let parent = first(where: { $0.id == parentID }) {
            path.insert(parent, at: 0)
            current = parent
        }

        return path
    }

    /// Returns all descendant IDs of the given item (for recursive delete)
    func descendants(of itemID: UUID) -> [UUID] {
        var result: [UUID] = []
        let directChildren = children(of: itemID)

        for child in directChildren {
            result.append(child.id)
            result.append(contentsOf: descendants(of: child.id))
        }

        return result
    }

    /// Returns all recipe IDs in the subtree of the given chapter
    func recipeIDs(in chapterID: UUID?) -> [UUID] {
        var result: [UUID] = []
        let items = children(of: chapterID)

        for item in items {
            if let recipeID = item.recipeID {
                result.append(recipeID)
            } else {
                // Recursively get recipes from subchapter
                result.append(contentsOf: recipeIDs(in: item.id))
            }
        }

        return result
    }
}
