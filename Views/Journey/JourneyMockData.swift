// Views/Journey/JourneyMockData.swift
// Mock data for SwiftUI Previews only
// Production code uses JourneyStore with real database

import Foundation

// MARK: - Mock Data Provider (for Previews)

enum JourneyMockData {

    static let inboxNodes: [JourneyNode] = [
        JourneyNode(
            section: .inbox,
            nodeType: .entry,
            title: "Meeting-Notizen importieren",
            content: "Die Notizen vom letzten Teammeeting müssen noch sortiert werden.",
            tags: ["Import", "ToDo"]
        ),
        JourneyNode(
            section: .inbox,
            nodeType: .entry,
            title: "Artikel über SwiftUI",
            content: "Interessanter Artikel zu @Observable macro.",
            tags: ["Lesen", "SwiftUI"]
        )
    ]

    static let journalNodes: [JourneyNode] = [
        JourneyNode(
            section: .journal,
            nodeType: .folder,
            title: "2025",
            children: [
                JourneyNode(
                    section: .journal,
                    nodeType: .folder,
                    title: "Dezember",
                    children: [
                        JourneyNode(
                            section: .journal,
                            nodeType: .entry,
                            title: "Jahresrückblick",
                            content: "Ein ereignisreiches Jahr geht zu Ende. AILO hat große Fortschritte gemacht...",
                            tags: ["Reflexion", "Jahr:2025"]
                        ),
                        JourneyNode(
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

    static let wikiNodes: [JourneyNode] = [
        JourneyNode(
            section: .wiki,
            nodeType: .folder,
            title: "Entwicklung",
            children: [
                JourneyNode(
                    section: .wiki,
                    nodeType: .folder,
                    title: "Swift",
                    children: [
                        JourneyNode(
                            section: .wiki,
                            nodeType: .entry,
                            title: "Async/Await Patterns",
                            content: "# Async/Await in Swift\n\nModernes Concurrency-Handling...",
                            tags: ["Swift", "Concurrency", "Referenz"]
                        ),
                        JourneyNode(
                            section: .wiki,
                            nodeType: .entry,
                            title: "Property Wrappers",
                            content: "# Property Wrappers\n\n@State, @Binding, @Published...",
                            tags: ["Swift", "SwiftUI"]
                        )
                    ]
                ),
                JourneyNode(
                    section: .wiki,
                    nodeType: .entry,
                    title: "SQLite Best Practices",
                    content: "Wichtige Erkenntnisse aus der AILO-Entwicklung...",
                    tags: ["SQLite", "Datenbank", "AILO"]
                )
            ]
        ),
        JourneyNode(
            section: .wiki,
            nodeType: .folder,
            title: "Projekte",
            children: [
                JourneyNode(
                    section: .wiki,
                    nodeType: .entry,
                    title: "AILO Architektur",
                    content: "Übersicht über die AILO App-Architektur...",
                    tags: ["AILO", "Architektur"]
                )
            ]
        )
    ]

    static let projectNodes: [JourneyNode] = [
        JourneyNode(
            section: .projects,
            nodeType: .folder,
            title: "AILO Development",
            children: [
                JourneyNode(
                    section: .projects,
                    nodeType: .task,
                    title: "Journey UI implementieren",
                    content: "Phase 1 des Journey-Features",
                    tags: ["Sprint:Current", "Priorität:Hoch"],
                    status: .inProgress,
                    dueDate: Calendar.current.date(byAdding: .day, value: 7, to: Date()),
                    progress: 30
                ),
                JourneyNode(
                    section: .projects,
                    nodeType: .task,
                    title: "Datenbank-Layer",
                    content: "SQLite Schema und DAO für Journey",
                    tags: ["Sprint:Next", "Priorität:Hoch"],
                    status: .open,
                    dueDate: Calendar.current.date(byAdding: .day, value: 14, to: Date()),
                    progress: 0
                ),
                JourneyNode(
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

    static func nodes(for section: JourneySection) -> [JourneyNode] {
        switch section {
        case .inbox: return inboxNodes
        case .journal: return journalNodes
        case .wiki: return wikiNodes
        case .projects: return projectNodes
        }
    }
}
