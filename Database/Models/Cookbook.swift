import Foundation

/// Ein Kochbuch das Rezepte und Kapitel enthält
public struct Cookbook: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String                     // Emoji (max 3 chars)
    public var keywords: String                 // Semikolon-getrennte Schlagwörter (Metadaten)
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    // Full initializer
    public init(
        id: UUID = UUID(),
        name: String,
        icon: String = "📚",
        keywords: String = "",
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = String(icon.prefix(3))
        self.keywords = keywords
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Custom decoding for migration
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "📚"
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, keywords, sortOrder, createdAt, updatedAt
    }

    /// Create a modified copy with updated timestamp
    public func updated(
        name: String? = nil,
        icon: String? = nil,
        keywords: String? = nil
    ) -> Cookbook {
        Cookbook(
            id: self.id,
            name: name ?? self.name,
            icon: icon ?? self.icon,
            keywords: keywords ?? self.keywords,
            sortOrder: self.sortOrder,
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
}

// MARK: - Array Extensions

extension Array where Element == Cookbook {
    /// Returns cookbook by ID
    func cookbook(withID id: UUID) -> Cookbook? {
        first(where: { $0.id == id })
    }

    /// Returns sorted by sortOrder
    func sorted() -> [Cookbook] {
        self.sorted { $0.sortOrder < $1.sortOrder }
    }
}
