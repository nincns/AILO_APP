// Database/Models/JourneyModels.swift
// Journey Feature - Data Models

import Foundation
import UniformTypeIdentifiers
import SwiftUI

// MARK: - UTType für Journey Node und Export

extension UTType {
    static let journeyNode = UTType(exportedAs: "com.ailo.journey.node")
    static let ailoExport = UTType(exportedAs: "com.ailo.journey.export")
}

// MARK: - Enums

public enum JourneySection: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox = "inbox"
    case journal = "journal"
    case wiki = "wiki"
    case projects = "projects"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return String(localized: "journey.section.inbox")
        case .journal: return String(localized: "journey.section.journal")
        case .wiki: return String(localized: "journey.section.wiki")
        case .projects: return String(localized: "journey.section.projects")
        }
    }

    public var icon: String {
        switch self {
        case .inbox: return "tray"
        case .journal: return "book"
        case .wiki: return "books.vertical"
        case .projects: return "checklist"
        }
    }

    public var color: String {
        switch self {
        case .inbox: return "orange"
        case .journal: return "purple"
        case .wiki: return "blue"
        case .projects: return "green"
        }
    }
}

public enum JourneyNodeType: String, Codable, CaseIterable, Sendable {
    case folder = "folder"
    case entry = "entry"
    case task = "task"

    public var icon: String {
        switch self {
        case .folder: return "folder"
        case .entry: return "doc.text"
        case .task: return "checkmark.circle"
        }
    }
}

public enum JourneyTaskStatus: String, Codable, CaseIterable, Sendable {
    case open = "open"
    case inProgress = "in_progress"
    case done = "done"
    case cancelled = "cancelled"

    public var title: String {
        switch self {
        case .open: return String(localized: "journey.status.open")
        case .inProgress: return String(localized: "journey.status.inProgress")
        case .done: return String(localized: "journey.status.done")
        case .cancelled: return String(localized: "journey.status.cancelled")
        }
    }

    public var icon: String {
        switch self {
        case .open: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    public var color: String {
        switch self {
        case .open: return "gray"
        case .inProgress: return "blue"
        case .done: return "green"
        case .cancelled: return "red"
        }
    }
}

public enum ContactRole: String, Codable, CaseIterable, Sendable {
    case assignee = "assignee"
    case owner = "owner"
    case stakeholder = "stakeholder"
    case reviewer = "reviewer"
    case contact = "contact"

    public var title: String {
        switch self {
        case .assignee: return String(localized: "journey.role.assignee")
        case .owner: return String(localized: "journey.role.owner")
        case .stakeholder: return String(localized: "journey.role.stakeholder")
        case .reviewer: return String(localized: "journey.role.reviewer")
        case .contact: return String(localized: "journey.role.contact")
        }
    }
}

// MARK: - Main Node Model

public struct JourneyNode: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var originId: UUID
    public var revision: Int
    public var parentId: UUID?
    public var section: JourneySection
    public var nodeType: JourneyNodeType
    public var title: String
    public var content: String?
    public var sortOrder: Int
    public var tags: [String]
    public var createdAt: Date
    public var modifiedAt: Date
    public var doingAt: Date?

    // Task-spezifisch
    public var status: JourneyTaskStatus?
    public var dueDate: Date?
    public var dueEndDate: Date?
    public var progress: Int?
    public var calendarEventId: String?

    // Kollaboration
    public var assignedTo: UUID?
    public var createdBy: UUID?
    public var completedAt: Date?
    public var completedBy: UUID?

    // Nicht in DB, für Tree-Darstellung
    public var children: [JourneyNode]?

    public init(
        id: UUID = UUID(),
        originId: UUID? = nil,
        revision: Int = 1,
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
        dueEndDate: Date? = nil,
        progress: Int? = nil,
        calendarEventId: String? = nil,
        assignedTo: UUID? = nil,
        createdBy: UUID? = nil,
        completedAt: Date? = nil,
        completedBy: UUID? = nil,
        children: [JourneyNode]? = nil
    ) {
        self.id = id
        self.originId = originId ?? id  // Default: originId = id bei Neuerstellung
        self.revision = revision
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
        self.dueEndDate = dueEndDate
        self.progress = progress
        self.calendarEventId = calendarEventId
        self.assignedTo = assignedTo
        self.createdBy = createdBy
        self.completedAt = completedAt
        self.completedBy = completedBy
        self.children = children
    }

    // Codable: children nicht in JSON (nur für Tree-Darstellung)
    private enum CodingKeys: String, CodingKey {
        case id, originId, revision, parentId, section, nodeType, title, content
        case sortOrder, tags, createdAt, modifiedAt, doingAt
        case status, dueDate, dueEndDate, progress, calendarEventId
        case assignedTo, createdBy, completedAt, completedBy
    }
}

// MARK: - Transferable Conformance (für Drag & Drop)

extension JourneyNode: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .journeyNode) { node in
            try JSONEncoder().encode(node)
        } importing: { data in
            try JSONDecoder().decode(JourneyNode.self, from: data)
        }
    }
}

// MARK: - Attachment Model

public struct JourneyAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var nodeId: UUID
    public var filename: String
    public var mimeType: String
    public var fileSize: Int64
    public var dataHash: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        nodeId: UUID,
        filename: String,
        mimeType: String,
        fileSize: Int64,
        dataHash: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.nodeId = nodeId
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.dataHash = dataHash
        self.createdAt = createdAt
    }
}

// MARK: - Contact Reference Model

public struct JourneyContactRef: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var nodeId: UUID
    public var contactId: String?
    public var displayName: String
    public var email: String?
    public var phone: String?
    public var role: ContactRole?
    public var note: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        nodeId: UUID,
        contactId: String? = nil,
        displayName: String,
        email: String? = nil,
        phone: String? = nil,
        role: ContactRole? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.nodeId = nodeId
        self.contactId = contactId
        self.displayName = displayName
        self.email = email
        self.phone = phone
        self.role = role
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - Blob Model (für Medien-Speicher)

public struct JourneyBlob: Equatable, Sendable {
    public var hash: String
    public var data: Data
    public var refCount: Int

    public init(hash: String, data: Data, refCount: Int = 1) {
        self.hash = hash
        self.data = data
        self.refCount = refCount
    }
}
