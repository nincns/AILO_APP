import Foundation

/// Ein "Kochrezept" das mehrere Katalog-Items zu einem kompletten Prompt kombiniert
/// Referenziert Items über deren presetID und generiert daraus einen zusammengesetzten Prompt
public struct PrePromptRecipe: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String                     // Emoji (max 3 chars)
    public var keywords: String                 // Semikolon-getrennte Schlagwörter
    public var itemIDs: [UUID]                  // Geordnete Liste der referenzierten Preset-IDs
    public var separator: String                // Trennzeichen zwischen Items (default: "\n\n")
    public var createdAt: Date
    public var updatedAt: Date

    // Full initializer
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "📖",
        keywords: String = "",
        itemIDs: [UUID] = [],
        separator: String = "\n\n",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = String(icon.prefix(3))
        self.keywords = keywords
        self.itemIDs = itemIDs
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
        itemIDs = try container.decodeIfPresent([UUID].self, forKey: .itemIDs) ?? []
        separator = try container.decodeIfPresent(String.self, forKey: .separator) ?? "\n\n"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, keywords, itemIDs, separator, createdAt, updatedAt
    }

    /// Create a modified copy with updated timestamp
    public func updated(
        name: String? = nil,
        icon: String? = nil,
        keywords: String? = nil,
        itemIDs: [UUID]? = nil,
        separator: String? = nil
    ) -> PrePromptRecipe {
        PrePromptRecipe(
            id: self.id,
            name: name ?? self.name,
            icon: icon ?? self.icon,
            keywords: keywords ?? self.keywords,
            itemIDs: itemIDs ?? self.itemIDs,
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

    /// Generate the combined prompt text from all referenced items
    /// - Parameter presets: The available presets to look up by ID
    /// - Returns: Combined prompt text
    public func generatePrompt(from presets: [AIPrePromptPreset]) -> String {
        let texts = itemIDs.compactMap { id in
            presets.first(where: { $0.id == id })?.text
        }
        return texts.joined(separator: separator)
    }

    /// Collect all keywords from the recipe and its referenced items
    /// - Parameter presets: The available presets to look up by ID
    /// - Returns: Combined keyword pairs (recipe keywords override item keywords)
    public func collectKeywords(from presets: [AIPrePromptPreset]) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []

        // Collect from items first
        for id in itemIDs {
            if let preset = presets.first(where: { $0.id == id }) {
                for pair in preset.keywordPairs {
                    // Only add if not already present
                    if !result.contains(where: { $0.key.lowercased() == pair.key.lowercased() }) {
                        result.append(pair)
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

    /// Get the resolved items in order
    /// - Parameter presets: The available presets to look up by ID
    /// - Returns: Ordered list of resolved presets
    public func resolveItems(from presets: [AIPrePromptPreset]) -> [AIPrePromptPreset] {
        itemIDs.compactMap { id in
            presets.first(where: { $0.id == id })
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
