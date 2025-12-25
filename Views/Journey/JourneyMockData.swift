// Views/Journey/JourneyMockData.swift
import Foundation

// MARK: - Enums (später nach Database/Models verschieben)

enum JourneySection: String, CaseIterable, Identifiable {
    case inbox = "inbox"
    case journal = "journal"
    case wiki = "wiki"
    case projects = "projects"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return String(localized: "journey.section.inbox")
        case .journal: return String(localized: "journey.section.journal")
        case .wiki: return String(localized: "journey.section.wiki")
        case .projects: return String(localized: "journey.section.projects")
        }
    }

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .journal: return "book"
        case .wiki: return "books.vertical"
        case .projects: return "checklist"
        }
    }

    var color: String {
        switch self {
        case .inbox: return "orange"
        case .journal: return "purple"
        case .wiki: return "blue"
        case .projects: return "green"
        }
    }
}

enum JourneyNodeType: String, CaseIterable {
    case folder
    case entry
    case task

    var icon: String {
        switch self {
        case .folder: return "folder"
        case .entry: return "doc.text"
        case .task: return "checkmark.circle"
        }
    }
}

enum JourneyTaskStatus: String, CaseIterable {
    case open = "open"
    case inProgress = "in_progress"
    case done = "done"
    case cancelled = "cancelled"

    var title: String {
        switch self {
        case .open: return String(localized: "journey.status.open")
        case .inProgress: return String(localized: "journey.status.inProgress")
        case .done: return String(localized: "journey.status.done")
        case .cancelled: return String(localized: "journey.status.cancelled")
        }
    }

    var icon: String {
        switch self {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    var color: String {
        switch self {
        case .open: return "gray"
        case .inProgress: return "blue"
        case .done: return "green"
        case .cancelled: return "red"
        }
    }
}

// MARK: - Mock Node Model

struct JourneyNodeMock: Identifiable {
    let id: UUID
    let parentId: UUID?
    let section: JourneySection
    let nodeType: JourneyNodeType
    let title: String
    let content: String?
    let sortOrder: Int
    let tags: [String]
    let createdAt: Date
    let modifiedAt: Date
    let doingAt: Date?

    // Task-spezifisch
    let status: JourneyTaskStatus?
    let dueDate: Date?
    let progress: Int?

    // Computed: Kinder (für Tree)
    var children: [JourneyNodeMock]?

    init(
        id: UUID = UUID(),
        parentId: UUID? = nil,
        section: JourneySection,
        nodeType: JourneyNodeType,
        title: String,
        content: String? = nil,
        sortOrder: Int = 0,
        tags: [String] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        doingAt: Date? = nil,
        status: JourneyTaskStatus? = nil,
        dueDate: Date? = nil,
        progress: Int? = nil,
        children: [JourneyNodeMock]? = nil
    ) {
        self.id = id
        self.parentId = parentId
        self.section = section
        self.nodeType = nodeType
        self.title = title
        self.content = content
        self.sortOrder = sortOrder
        self.tags = tags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.doingAt = doingAt
        self.status = status
        self.dueDate = dueDate
        self.progress = progress
        self.children = children
    }
}

// MARK: - Mock Data Provider

struct JourneyMockData {

    static let inbox: [JourneyNodeMock] = [
        JourneyNodeMock(
            section: .inbox,
            nodeType: .entry,
            title: "Meeting-Notizen importieren",
            content: "Die Notizen vom letzten Teammeeting müssen noch sortiert werden.",
            tags: ["Import", "ToDo"]
        ),
        JourneyNodeMock(
            section: .inbox,
            nodeType: .entry,
            title: "Artikel über SwiftUI",
            content: "Interessanter Artikel zu @Observable macro.",
            tags: ["Lesen", "SwiftUI"]
        )
    ]

    static let journal: [JourneyNodeMock] = [
        JourneyNodeMock(
            section: .journal,
            nodeType: .folder,
            title: "2025",
            children: [
                JourneyNodeMock(
                    section: .journal,
                    nodeType: .folder,
                    title: "Dezember",
                    children: [
                        JourneyNodeMock(
                            section: .journal,
                            nodeType: .entry,
                            title: "Jahresrückblick",
                            content: "Ein ereignisreiches Jahr geht zu Ende. AILO hat große Fortschritte gemacht...",
                            tags: ["Reflexion", "Jahr:2025"]
                        ),
                        JourneyNodeMock(
                            section: .journal,
                            nodeType: .entry,
                            title: "Journey Feature gestartet",
                            content: "Heute haben wir mit der Konzeption des Journey-Features begonnen. Spannende neue Möglichkeiten!",
                            tags: ["AILO", "Feature"]
                        )
                    ]
                )
            ]
        )
    ]

    static let wiki: [JourneyNodeMock] = [
        JourneyNodeMock(
            section: .wiki,
            nodeType: .folder,
            title: "Entwicklung",
            children: [
                JourneyNodeMock(
                    section: .wiki,
                    nodeType: .folder,
                    title: "Swift",
                    children: [
                        JourneyNodeMock(
                            section: .wiki,
                            nodeType: .entry,
                            title: "Async/Await Patterns",
                            content: "# Async/Await in Swift\n\nModernes Concurrency-Handling...",
                            tags: ["Swift", "Concurrency", "Referenz"]
                        ),
                        JourneyNodeMock(
                            section: .wiki,
                            nodeType: .entry,
                            title: "Property Wrappers",
                            content: "# Property Wrappers\n\n@State, @Binding, @Published...",
                            tags: ["Swift", "SwiftUI"]
                        )
                    ]
                ),
                JourneyNodeMock(
                    section: .wiki,
                    nodeType: .entry,
                    title: "SQLite Best Practices",
                    content: "Wichtige Erkenntnisse aus der AILO-Entwicklung...",
                    tags: ["SQLite", "Datenbank", "AILO"]
                )
            ]
        ),
        JourneyNodeMock(
            section: .wiki,
            nodeType: .folder,
            title: "Projekte",
            children: [
                JourneyNodeMock(
                    section: .wiki,
                    nodeType: .entry,
                    title: "AILO Architektur",
                    content: "Übersicht über die AILO App-Architektur...",
                    tags: ["AILO", "Architektur"]
                )
            ]
        )
    ]

    static let projects: [JourneyNodeMock] = [
        JourneyNodeMock(
            section: .projects,
            nodeType: .folder,
            title: "AILO Development",
            children: [
                JourneyNodeMock(
                    section: .projects,
                    nodeType: .task,
                    title: "Journey UI implementieren",
                    content: "Phase 1 des Journey-Features",
                    tags: ["Sprint:Current", "Priorität:Hoch"],
                    status: .inProgress,
                    dueDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()),
                    progress: 30
                ),
                JourneyNodeMock(
                    section: .projects,
                    nodeType: .task,
                    title: "Datenbank-Layer",
                    content: "SQLite Schema und DAO für Journey",
                    tags: ["Sprint:Next", "Priorität:Hoch"],
                    status: .open,
                    dueDate: Calendar.current.date(byAdding: .day, value: 14, to: Date()),
                    progress: 0
                ),
                JourneyNodeMock(
                    section: .projects,
                    nodeType: .task,
                    title: "Mail Attachment Fix",
                    content: "PDF-Anhänge werden abgeschnitten",
                    tags: ["Bug", "Priorität:Kritisch"],
                    status: .done,
                    progress: 100
                )
            ]
        )
    ]

    static func nodes(for section: JourneySection) -> [JourneyNodeMock] {
        switch section {
        case .inbox: return inbox
        case .journal: return journal
        case .wiki: return wiki
        case .projects: return projects
        }
    }
}
