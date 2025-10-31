import Foundation

// MARK: - AI PrePrompt Presets (aus LogsView ausgelagert)
public struct AIPrePromptPreset: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var name: String
    public var text: String

    public init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}
