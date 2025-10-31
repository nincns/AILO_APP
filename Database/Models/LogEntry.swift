// Core/Models/LogEntry.swift
import Foundation

enum EntryType: String, Codable, CaseIterable, Identifiable {
    case text
    case audio
    var id: String { rawValue }

    var titleLabel: String {
        switch self { case .text: return "Text"; case .audio: return "Audio" }
    }
}

struct LogEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var date: Date = Date()
    var type: EntryType
    var title: String?
    var text: String?
    var audioFileName: String?

    // NEU:
    var category: String?
    var tags: [String] = []
    var reminderDate: Date?
    // AI enhancement (nur für Text-Logs)
    var useAI: Bool? = nil
    var aiText: String? = nil

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        type: EntryType,
        title: String? = nil,
        text: String? = nil,
        audioFileName: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        reminderDate: Date? = nil,
        useAI: Bool? = nil,
        aiText: String? = nil
    ) {
        self.id = id
        self.date = date
        self.type = type
        self.title = title
        self.text = text
        self.audioFileName = audioFileName
        self.category = category
        self.tags = tags
        self.reminderDate = reminderDate
        self.useAI = useAI
        self.aiText = aiText
    }

    static func text(_ value: String, title: String? = nil,
                     category: String? = nil, tags: [String] = [],
                     reminderDate: Date? = nil,
                     useAI: Bool? = nil, aiText: String? = nil) -> LogEntry {
        LogEntry(type: .text, title: title, text: value,
                 category: category, tags: tags, reminderDate: reminderDate,
                 useAI: useAI, aiText: aiText)
    }

    static func audio(fileName: String, title: String? = nil,
                      category: String? = nil, tags: [String] = [],
                      reminderDate: Date? = nil) -> LogEntry {
        LogEntry(type: .audio, title: title, audioFileName: fileName,
                 category: category, tags: tags, reminderDate: reminderDate)
    }
}
