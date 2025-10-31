import Foundation

// Basis-Modelle ohne Abhängigkeiten
public struct MailHeader: Sendable, Identifiable {
    public let id: String      // uid
    public let from: String
    public let subject: String
    public let date: Date?
    public let flags: [String]
    
    public init(id: String, from: String, subject: String, date: Date?, flags: [String]) {
        self.id = id
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}
