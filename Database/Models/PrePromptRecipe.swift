import Foundation

/// Ein "Kochrezept" das mehrere Katalog-Elemente zu einem kompletten Prompt kombiniert
/// Referenziert sowohl Kategorien (für Struktur/Kontext) als auch Items (für Inhalt)
/// über deren PrePromptMenuItem-ID
public struct PrePromptRecipe: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String                     // Emoji (max 3 chars)
    public var keywords: String                 // Semikolon-getrennte Schlagwörter
    public var elementIDs: [UUID]               // Geordnete Liste der MenuItem-IDs (Kategorien + Items)
    public var separator: String                // Trennzeichen zwischen Elementen (default: "\n\n")
    public var createdAt: Date
    public var updatedAt: Date

    // Full initializer
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "📖",
        keywords: String = "",
        elementIDs: [UUID] = [],
        separator: String = "\n\n",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = String(icon.prefix(3))
        self.keywords = keywords
        self.elementIDs = elementIDs
        self.separator = separator
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoding for migration
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "📖"
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        // Migration: Support old itemIDs field
        if let elements = try container.decodeIfPresent([UUID].self, forKey: .elementIDs) {
            elementIDs = elements
        } else if let items = try container.decodeIfPresent([UUID].self, forKey: .itemIDs) {
            elementIDs = items
        } else {
            elementIDs = []
        }
        separator = try container.decodeIfPresent(String.self, forKey: .separator) ?? "\n\n"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, keywords, elementIDs, itemIDs, separator, createdAt, updatedAt
    }

    // Custom encoding (itemIDs is only for migration decoding)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(icon, forKey: .icon)
        try container.encode(keywords, forKey: .keywords)
        try container.encode(elementIDs, forKey: .elementIDs)
        try container.encode(separator, forKey: .separator)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Create a modified copy with updated timestamp
    public func updated(
        name: String? = nil,
        icon: String? = nil,
        keywords: String? = nil,
        elementIDs: [UUID]? = nil,
        separator: String? = nil
    ) -> PrePromptRecipe {
        PrePromptRecipe(
            id: self.id,
            name: name ?? self.name,
            icon: icon ?? self.icon,
            keywords: keywords ?? self.keywords,
            elementIDs: elementIDs ?? self.elementIDs,
            separator: separator ?? self.separator,
            createdAt: self.createdAt,
            updatedAt: Date()
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

    /// Generate the combined prompt text from all referenced elements
    /// Categories become section headers with their metadata
    /// Items provide the actual prompt content
    public func generatePrompt(from menuItems: [PrePromptMenuItem], presets: [AIPrePromptPreset]) -> String {
        var parts: [String] = []

        for elementID in elementIDs {
            if let menuItem = menuItems.first(where: { $0.id == elementID }) {
                if menuItem.isFolder {
                    // Category: Use as section header with metadata
                    var sectionParts: [String] = []
                    sectionParts.append("## \(menuItem.name)")

                    // Add category keywords as context
                    if !menuItem.keywords.isEmpty {
                        let contextLines = menuItem.keywordPairs.map { "**\($0.key):** \($0.value)" }
                        sectionParts.append(contentsOf: contextLines)
                    }

                    parts.append(sectionParts.joined(separator: "\n"))
                } else if let presetID = menuItem.presetID,
                          let preset = presets.first(where: { $0.id == presetID }) {
                    // Item: Use preset text
                    parts.append(preset.text)
                }
            }
        }

        return parts.joined(separator: separator)
    }

    /// Collect all keywords from the recipe, categories, and items
    /// Later entries override earlier ones (recipe keywords have highest priority)
    public func collectKeywords(from menuItems: [PrePromptMenuItem], presets: [AIPrePromptPreset]) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []

        // Collect from elements in order
        for elementID in elementIDs {
            if let menuItem = menuItems.first(where: { $0.id == elementID }) {
                // Add category keywords
                for pair in menuItem.keywordPairs {
                    if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                        result.append(pair)
                    }
                }

                // Add preset keywords if it's an item
                if let presetID = menuItem.presetID,
                   let preset = presets.first(where: { $0.id == presetID }) {
                    for pair in preset.keywordPairs {
                        if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                            result.append(pair)
                        }
                    }
                }
            }
        }

        // Recipe keywords override
        for pair in keywordPairs {
            if let index = result.firstIndex(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                result[index] = pair
            } else {
                result.append(pair)
            }
        }

        return result
    }

    /// Resolve elements to their menu items
    public func resolveElements(from menuItems: [PrePromptMenuItem]) -> [PrePromptMenuItem] {
        elementIDs.compactMap { id in
            menuItems.first(where: { $0.id == id })
        }
    }
}

// MARK: - Array Extensions

extension Array where Element == PrePromptRecipe {
    /// Returns recipe by ID
    func recipe(withID id: UUID) -> PrePromptRecipe? {
        first(where: { $0.id == id })
    }
}
