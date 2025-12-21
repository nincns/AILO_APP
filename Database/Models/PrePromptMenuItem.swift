import Foundation

/// Hierarchisches Menü-Item für Pre-Prompt Navigation
/// Kann entweder ein Ordner (children) oder ein Pre-Prompt-Verweis sein
public struct PrePromptMenuItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var parentID: UUID?              // nil = Root-Level
    public var name: String                 // Anzeigename im Menü
    public var icon: String                 // Emoji
    public var keywords: String             // Semikolon-getrennte Schlagwörter
    public var sortOrder: Int

    // Wenn presetID gesetzt → Blatt-Element (verweist auf Pre-Prompt)
    // Wenn nil → Ordner/Kategorie
    public var presetID: UUID?

    public var isFolder: Bool { presetID == nil }
    public var isPreset: Bool { presetID != nil }

    // Full initializer
    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        icon: String = "📁",
        keywords: String = "",
        sortOrder: Int = 0,
        presetID: UUID? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.icon = icon
        self.keywords = keywords
        self.sortOrder = sortOrder
        self.presetID = presetID
    }

    // Custom decoding for migration from old format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "📁"
        keywords = try container.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, name, icon, keywords, sortOrder, presetID
    }

    /// Convenience initializer for folder
    public static func folder(
        name: String,
        icon: String = "📁",
        keywords: String = "",
        parentID: UUID? = nil,
        sortOrder: Int = 0
    ) -> PrePromptMenuItem {
        PrePromptMenuItem(
            parentID: parentID,
            name: name,
            icon: icon,
            keywords: keywords,
            sortOrder: sortOrder,
            presetID: nil
        )
    }

    /// Convenience initializer for preset reference
    public static func preset(
        name: String,
        icon: String = "💬",
        keywords: String = "",
        parentID: UUID? = nil,
        sortOrder: Int = 0,
        presetID: UUID
    ) -> PrePromptMenuItem {
        PrePromptMenuItem(
            parentID: parentID,
            name: name,
            icon: icon,
            keywords: keywords,
            sortOrder: sortOrder,
            presetID: presetID
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

extension Array where Element == PrePromptMenuItem {
    /// Returns children of the given parent (nil = root level)
    func children(of parentID: UUID?) -> [PrePromptMenuItem] {
        filter { $0.parentID == parentID }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Returns the path from root to the given item (breadcrumb)
    func path(to itemID: UUID) -> [PrePromptMenuItem] {
        guard let item = first(where: { $0.id == itemID }) else { return [] }

        var path: [PrePromptMenuItem] = [item]
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

    /// Returns all preset IDs in the subtree of the given folder
    func presetIDs(in folderID: UUID?) -> [UUID] {
        var result: [UUID] = []
        let items = children(of: folderID)

        for item in items {
            if let presetID = item.presetID {
                result.append(presetID)
            } else {
                // Recursively get presets from subfolder
                result.append(contentsOf: presetIDs(in: item.id))
            }
        }

        return result
    }
}
