import Foundation

// MARK: - AI PrePrompt Preset
/// Content model for a pre-prompt template
/// The hierarchy/organization is handled by PrePromptMenuItem
public struct AIPrePromptPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String

    // Metadata
    public var icon: String
    public var isDefault: Bool
    public var createdAt: Date
    public var updatedAt: Date

    // Full initializer
    public init(
        id: UUID = UUID(),
        name: String,
        text: String,
        icon: String = "💬",
        isDefault: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.icon = icon
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Legacy initializer for backward compatibility
    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
        self.icon = "💬"
        self.isDefault = false
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Custom decoding for migration from old format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        text = try container.decode(String.self, forKey: .text)

        // Optional fields with defaults for migration
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? "💬"
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, text, icon, isDefault, createdAt, updatedAt
    }

    /// Create a modified copy with updated timestamp
    public func updated(name: String? = nil, text: String? = nil, icon: String? = nil, isDefault: Bool? = nil) -> AIPrePromptPreset {
        AIPrePromptPreset(
            id: self.id,
            name: name ?? self.name,
            text: text ?? self.text,
            icon: icon ?? self.icon,
            isDefault: isDefault ?? self.isDefault,
            createdAt: self.createdAt,
            updatedAt: Date()
        )
    }
}

// MARK: - Array Extensions

extension Array where Element == AIPrePromptPreset {
    /// Returns the default preset, or nil if none
    func defaultPreset() -> AIPrePromptPreset? {
        first(where: { $0.isDefault })
    }

    /// Returns preset by ID
    func preset(withID id: UUID) -> AIPrePromptPreset? {
        first(where: { $0.id == id })
    }
}
