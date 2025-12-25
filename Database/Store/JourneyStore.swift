// Database/Store/JourneyStore.swift
// Journey Feature - Observable Store for SwiftUI
// Manages journey nodes, attachments, and contacts

import Foundation
import Combine

@MainActor
public final class JourneyStore: ObservableObject {

    // MARK: - Published Properties

    /// Tree-strukturierte Nodes pro Section
    @Published public private(set) var inboxNodes: [JourneyNode] = []
    @Published public private(set) var journalNodes: [JourneyNode] = []
    @Published public private(set) var wikiNodes: [JourneyNode] = []
    @Published public private(set) var projectNodes: [JourneyNode] = []

    /// Suchergebnisse
    @Published public private(set) var searchResults: [JourneyNode] = []

    /// Aktuell ausgewählter Node (für Detail-View)
    @Published public var selectedNode: JourneyNode?

    /// Loading/Error State
    @Published public private(set) var isLoading: Bool = false
    @Published public var lastError: String?

    // MARK: - DAO Reference

    private var dao: JourneyDAO?

    // MARK: - Singleton

    public static let shared = JourneyStore()

    private init() {}

    // MARK: - Setup

    /// Wird von DAOFactory aufgerufen
    public func setDAO(_ dao: JourneyDAO) {
        self.dao = dao
        Task {
            await loadAllSections()
        }
    }

    // MARK: - Load Data

    /// Lädt alle Sections
    public func loadAllSections() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let inbox = loadSection(.inbox)
            async let journal = loadSection(.journal)
            async let wiki = loadSection(.wiki)
            async let projects = loadSection(.projects)

            let results = await (inbox, journal, wiki, projects)
            inboxNodes = results.0
            journalNodes = results.1
            wikiNodes = results.2
            projectNodes = results.3

            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("❌ JourneyStore.loadAllSections failed: \(error)")
        }
    }

    /// Lädt eine einzelne Section
    public func loadSection(_ section: JourneySection) async -> [JourneyNode] {
        guard let dao = dao else {
            print("⚠️ JourneyStore: DAO not initialized")
            return []
        }

        do {
            let tree = try dao.getTree(section: section)
            return tree
        } catch {
            print("❌ JourneyStore.loadSection(\(section)) failed: \(error)")
            return []
        }
    }

    /// Lädt Section und aktualisiert Published Property
    public func refreshSection(_ section: JourneySection) async {
        let tree = await loadSection(section)

        switch section {
        case .inbox: inboxNodes = tree
        case .journal: journalNodes = tree
        case .wiki: wikiNodes = tree
        case .projects: projectNodes = tree
        }
    }

    /// Gibt Nodes für eine Section zurück
    public func nodes(for section: JourneySection) -> [JourneyNode] {
        switch section {
        case .inbox: return inboxNodes
        case .journal: return journalNodes
        case .wiki: return wikiNodes
        case .projects: return projectNodes
        }
    }

    // MARK: - CRUD Operations

    /// Erstellt einen neuen Node
    public func createNode(
        section: JourneySection,
        nodeType: JourneyNodeType,
        title: String,
        content: String? = nil,
        parentId: UUID? = nil,
        tags: [String] = []
    ) async throws -> JourneyNode {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        let node = JourneyNode(
            section: section,
            nodeType: nodeType,
            title: title,
            content: content,
            parentId: parentId,
            tags: tags
        )

        try dao.insertNode(node)
        await refreshSection(section)

        return node
    }

    /// Aktualisiert einen Node
    public func updateNode(_ node: JourneyNode) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        try dao.updateNode(node)
        await refreshSection(node.section)

        // Update selectedNode if it's the same
        if selectedNode?.id == node.id {
            selectedNode = node
        }
    }

    /// Löscht einen Node (CASCADE löscht Kinder, Attachments, Contacts)
    public func deleteNode(_ node: JourneyNode) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        try dao.deleteNode(id: node.id)
        await refreshSection(node.section)

        if selectedNode?.id == node.id {
            selectedNode = nil
        }
    }

    /// Verschiebt einen Node zu neuem Parent
    public func moveNode(_ node: JourneyNode, toParent newParentId: UUID?, sortOrder: Int? = nil) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        try dao.moveNode(id: node.id, toParent: newParentId, sortOrder: sortOrder)
        await refreshSection(node.section)
    }

    // MARK: - Search

    /// Sucht in allen Sections oder einer bestimmten
    public func search(query: String, section: JourneySection? = nil) async {
        guard let dao = dao, !query.isEmpty else {
            searchResults = []
            return
        }

        do {
            searchResults = try dao.search(query: query, section: section)
        } catch {
            print("❌ JourneyStore.search failed: \(error)")
            searchResults = []
        }
    }

    /// Leert Suchergebnisse
    public func clearSearch() {
        searchResults = []
    }

    // MARK: - Attachments

    /// Lädt Attachments für einen Node
    public func getAttachments(for nodeId: UUID) async throws -> [JourneyAttachment] {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        return try dao.getAttachments(nodeId: nodeId)
    }

    /// Fügt Attachment hinzu
    public func addAttachment(_ attachment: JourneyAttachment, withData data: Data) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        // Blob speichern (dedupliziert)
        let blob = JourneyBlob(hash: attachment.dataHash, data: data)
        try dao.insertOrUpdateBlob(blob)

        // Attachment-Referenz speichern
        try dao.insertAttachment(attachment)
    }

    /// Löscht Attachment
    public func deleteAttachment(_ attachment: JourneyAttachment) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        // Attachment löschen
        try dao.deleteAttachment(id: attachment.id)

        // Blob-Referenz dekrementieren
        try dao.decrementBlobRef(hash: attachment.dataHash)
    }

    /// Lädt Blob-Daten für ein Attachment
    public func getBlobData(hash: String) async throws -> Data? {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        return try dao.getBlob(hash: hash)?.data
    }

    // MARK: - Contacts

    /// Lädt Kontakt-Referenzen für einen Node
    public func getContacts(for nodeId: UUID) async throws -> [JourneyContactRef] {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        return try dao.getContactRefs(nodeId: nodeId)
    }

    /// Fügt Kontakt-Referenz hinzu
    public func addContact(_ contact: JourneyContactRef) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        try dao.insertContactRef(contact)
    }

    /// Löscht Kontakt-Referenz
    public func deleteContact(_ contact: JourneyContactRef) async throws {
        guard let dao = dao else {
            throw JourneyStoreError.daoNotInitialized
        }

        try dao.deleteContactRef(id: contact.id)
    }

    // MARK: - Task-spezifische Operationen

    /// Alle offenen Tasks für Projects
    public var openTasks: [JourneyNode] {
        flattenNodes(projectNodes).filter { node in
            node.nodeType == .task && node.status != .done && node.status != .cancelled
        }
    }

    /// Überfällige Tasks
    public var overdueTasks: [JourneyNode] {
        let now = Date()
        return openTasks.filter { node in
            guard let dueDate = node.dueDate else { return false }
            return dueDate < now
        }
    }

    /// Tasks für heute
    public var todayTasks: [JourneyNode] {
        let calendar = Calendar.current
        return openTasks.filter { node in
            guard let dueDate = node.dueDate else { return false }
            return calendar.isDateInToday(dueDate)
        }
    }

    /// Task-Status aktualisieren
    public func updateTaskStatus(_ node: JourneyNode, status: JourneyTaskStatus) async throws {
        var updated = node
        updated.status = status

        if status == .done {
            updated.completedAt = Date()
            updated.progress = 100
        } else if status == .inProgress {
            updated.doingAt = Date()
        }

        try await updateNode(updated)
    }

    // MARK: - Helpers

    /// Flacht Baum zu Liste ab
    private func flattenNodes(_ nodes: [JourneyNode]) -> [JourneyNode] {
        var result: [JourneyNode] = []
        for node in nodes {
            result.append(node)
            if let children = node.children {
                result.append(contentsOf: flattenNodes(children))
            }
        }
        return result
    }
}

// MARK: - Error Types

public enum JourneyStoreError: Error, LocalizedError {
    case daoNotInitialized
    case nodeNotFound(UUID)
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case .daoNotInitialized:
            return "Journey database not initialized"
        case .nodeNotFound(let id):
            return "Node not found: \(id)"
        case .invalidOperation(let message):
            return "Invalid operation: \(message)"
        }
    }
}
