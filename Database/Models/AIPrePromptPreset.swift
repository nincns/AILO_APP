import Foundation

// MARK: - Pre-Prompt Context (specific use case)
public enum PrePromptContext: String, Codable, CaseIterable, Sendable {
    case mailForward    = "mail.forward"
    case mailReply      = "mail.reply"
    case mailAnalyze    = "mail.analyze"
    case mailSummarize  = "mail.summarize"
    case noteProtocol   = "note.protocol"
    case noteCorrect    = "note.correct"
    case noteStructure  = "note.structure"
    case general        = "general"

    public var localizedName: String {
        switch self {
        case .mailForward:   return String(localized: "preprompt.context.mail.forward")
        case .mailReply:     return String(localized: "preprompt.context.mail.reply")
        case .mailAnalyze:   return String(localized: "preprompt.context.mail.analyze")
        case .mailSummarize: return String(localized: "preprompt.context.mail.summarize")
        case .noteProtocol:  return String(localized: "preprompt.context.note.protocol")
        case .noteCorrect:   return String(localized: "preprompt.context.note.correct")
        case .noteStructure: return String(localized: "preprompt.context.note.structure")
        case .general:       return String(localized: "preprompt.context.general")
        }
    }

    public var icon: String {
        switch self {
        case .mailForward:   return "arrowshape.turn.up.right"
        case .mailReply:     return "arrowshape.turn.up.left"
        case .mailAnalyze:   return "magnifyingglass.circle"
        case .mailSummarize: return "doc.text.magnifyingglass"
        case .noteProtocol:  return "list.clipboard"
        case .noteCorrect:   return "pencil.and.outline"
        case .noteStructure: return "text.alignleft"
        case .general:       return "text.bubble"
        }
    }

    public var category: PrePromptCategory {
        switch self {
        case .mailForward, .mailReply, .mailAnalyze, .mailSummarize:
            return .mail
        case .noteProtocol, .noteCorrect, .noteStructure:
            return .notes
        case .general:
            return .general
        }
    }
}

// MARK: - Pre-Prompt Category (grouping)
public enum PrePromptCategory: String, Codable, CaseIterable, Sendable {
    case mail     = "mail"
    case notes    = "notes"
    case general  = "general"

    public var localizedName: String {
        switch self {
        case .mail:    return String(localized: "preprompt.category.mail")
        case .notes:   return String(localized: "preprompt.category.notes")
        case .general: return String(localized: "preprompt.category.general")
        }
    }

    public var icon: String {
        switch self {
        case .mail:    return "envelope"
        case .notes:   return "note.text"
        case .general: return "text.bubble"
        }
    }

    public var contexts: [PrePromptContext] {
        switch self {
        case .mail:
            return [.mailForward, .mailReply, .mailAnalyze, .mailSummarize]
        case .notes:
            return [.noteProtocol, .noteCorrect, .noteStructure]
        case .general:
            return [.general]
        }
    }
}

// MARK: - AI PrePrompt Preset
public struct AIPrePromptPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var text: String

    // Metadata (v2)
    public var category: PrePromptCategory
    public var context: PrePromptContext
    public var icon: String
    public var sortOrder: Int
    public var isDefault: Bool

    // Full initializer
    public init(
        id: UUID = UUID(),
        name: String,
        text: String,
        category: PrePromptCategory = .general,
        context: PrePromptContext = .general,
        icon: String? = nil,
        sortOrder: Int = 0,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.category = category
        self.context = context
        self.icon = icon ?? context.icon
        self.sortOrder = sortOrder
        self.isDefault = isDefault
    }

    // Legacy initializer for backward compatibility
    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
        self.category = .general
        self.context = .general
        self.icon = "text.bubble"
        self.sortOrder = 0
        self.isDefault = false
    }

    // Custom decoding for migration from old format
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        text = try container.decode(String.self, forKey: .text)

        // Optional fields with defaults for migration
        category = try container.decodeIfPresent(PrePromptCategory.self, forKey: .category) ?? .general
        context = try container.decodeIfPresent(PrePromptContext.self, forKey: .context) ?? .general
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? context.icon
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, text, category, context, icon, sortOrder, isDefault
    }
}
