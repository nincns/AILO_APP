import Foundation

/// Hierarchisches Menü-Item für Pre-Prompt Navigation
/// Kann entweder ein Ordner (children) oder ein Pre-Prompt-Verweis sein
public struct PrePromptMenuItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var parentID: UUID?              // nil = Root-Level
    public var name: String                 // Anzeigename im Menü
    public var icon: String                 // Emoji
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
        sortOrder: Int = 0,
        presetID: UUID? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.icon = icon
        self.sortOrder = sortOrder
        self.presetID = presetID
    }

    /// Convenience initializer for folder
    public static func folder(
        name: String,
        icon: String = "📁",
        parentID: UUID? = nil,
        sortOrder: Int = 0
    ) -> PrePromptMenuItem {
        PrePromptMenuItem(
            parentID: parentID,
            name: name,
            icon: icon,
            sortOrder: sortOrder,
            presetID: nil
        )
    }

    /// Convenience initializer for preset reference
    public static func preset(
        name: String,
        icon: String = "💬",
        parentID: UUID? = nil,
        sortOrder: Int = 0,
        presetID: UUID
    ) -> PrePromptMenuItem {
        PrePromptMenuItem(
            parentID: parentID,
            name: name,
            icon: icon,
            sortOrder: sortOrder,
            presetID: presetID
        )
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
