// Database/DAO/JourneyDAO.swift
// Journey Feature - Data Access Object
// CRUD operations for journey_nodes, journey_attachments, journey_contact_refs, journey_blobs

import Foundation
import SQLite3

public class JourneyDAO: BaseDAO {

    // MARK: - Schema Initialization

    public func initializeSchema() throws {
        let statements = JourneySchema.createStatements()
        for sql in statements {
            try exec(sql)
        }
    }

    // MARK: - Node CRUD

    public func insertNode(_ node: JourneyNode) throws {
        let sql = """
            INSERT INTO \(JourneySchema.tNodes) (
                id, origin_id, revision, parent_id, section, node_type, title, content,
                sort_order, tags, created_at, modified_at, doing_at,
                status, due_date, progress, calendar_event_id,
                assigned_to, created_by, completed_at, completed_by
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, node.id)
            bindUUID(stmt, 2, node.originId)
            bindInt(stmt, 3, node.revision)
            bindUUID(stmt, 4, node.parentId)
            bindText(stmt, 5, node.section.rawValue)
            bindText(stmt, 6, node.nodeType.rawValue)
            bindText(stmt, 7, node.title)
            bindText(stmt, 8, node.content)
            bindInt(stmt, 9, node.sortOrder)
            bindTagsJSON(stmt, 10, node.tags)
            bindDate(stmt, 11, node.createdAt)
            bindDate(stmt, 12, node.modifiedAt)
            bindDate(stmt, 13, node.doingAt)
            bindText(stmt, 14, node.status?.rawValue)
            bindDate(stmt, 15, node.dueDate)
            bindInt(stmt, 16, node.progress)
            bindText(stmt, 17, node.calendarEventId)
            bindUUID(stmt, 18, node.assignedTo)
            bindUUID(stmt, 19, node.createdBy)
            bindDate(stmt, 20, node.completedAt)
            bindUUID(stmt, 21, node.completedBy)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "insertNode")
            }
        }
    }

    public func updateNode(_ node: JourneyNode) throws {
        let sql = """
            UPDATE \(JourneySchema.tNodes) SET
                origin_id = ?, revision = ?, parent_id = ?, section = ?, node_type = ?,
                title = ?, content = ?, sort_order = ?, tags = ?, modified_at = ?,
                doing_at = ?, status = ?, due_date = ?, progress = ?, calendar_event_id = ?,
                assigned_to = ?, created_by = ?, completed_at = ?, completed_by = ?
            WHERE id = ?
            """

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, node.originId)
            bindInt(stmt, 2, node.revision)
            bindUUID(stmt, 3, node.parentId)
            bindText(stmt, 4, node.section.rawValue)
            bindText(stmt, 5, node.nodeType.rawValue)
            bindText(stmt, 6, node.title)
            bindText(stmt, 7, node.content)
            bindInt(stmt, 8, node.sortOrder)
            bindTagsJSON(stmt, 9, node.tags)
            bindDate(stmt, 10, Date())  // modifiedAt = now
            bindDate(stmt, 11, node.doingAt)
            bindText(stmt, 12, node.status?.rawValue)
            bindDate(stmt, 13, node.dueDate)
            bindInt(stmt, 14, node.progress)
            bindText(stmt, 15, node.calendarEventId)
            bindUUID(stmt, 16, node.assignedTo)
            bindUUID(stmt, 17, node.createdBy)
            bindDate(stmt, 18, node.completedAt)
            bindUUID(stmt, 19, node.completedBy)
            bindUUID(stmt, 20, node.id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "updateNode")
            }
        }
    }

    public func deleteNode(id: UUID) throws {
        // CASCADE delete handles children, attachments, contact refs
        let sql = "DELETE FROM \(JourneySchema.tNodes) WHERE id = ?"

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "deleteNode")
            }
        }
    }

    public func getNode(id: UUID) throws -> JourneyNode? {
        let sql = "SELECT * FROM \(JourneySchema.tNodes) WHERE id = ?"

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, id)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }

            return parseNode(stmt)
        }
    }

    // MARK: - Tree Queries

    public func getRootNodes(section: JourneySection) throws -> [JourneyNode] {
        let sql = """
            SELECT * FROM \(JourneySchema.tNodes)
            WHERE section = ? AND parent_id IS NULL
            ORDER BY sort_order ASC, created_at DESC
            """

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindText(stmt, 1, section.rawValue)

            var nodes: [JourneyNode] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                nodes.append(parseNode(stmt))
            }
            return nodes
        }
    }

    public func getChildren(parentId: UUID) throws -> [JourneyNode] {
        let sql = """
            SELECT * FROM \(JourneySchema.tNodes)
            WHERE parent_id = ?
            ORDER BY sort_order ASC, created_at DESC
            """

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, parentId)

            var nodes: [JourneyNode] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                nodes.append(parseNode(stmt))
            }
            return nodes
        }
    }

    /// Lädt kompletten Baum für eine Section (rekursiv)
    public func getTree(section: JourneySection) throws -> [JourneyNode] {
        // Erst alle Nodes der Section laden
        let sql = """
            SELECT * FROM \(JourneySchema.tNodes)
            WHERE section = ?
            ORDER BY parent_id NULLS FIRST, sort_order ASC, created_at DESC
            """

        let allNodes: [JourneyNode] = try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindText(stmt, 1, section.rawValue)

            var nodes: [JourneyNode] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                nodes.append(parseNode(stmt))
            }
            return nodes
        }

        // Baum aus flacher Liste bauen
        return buildTree(from: allNodes)
    }

    /// Baut rekursiv Baum aus flacher Node-Liste
    private func buildTree(from nodes: [JourneyNode]) -> [JourneyNode] {
        // Lookup by ID
        var nodeById: [UUID: JourneyNode] = [:]
        for node in nodes {
            nodeById[node.id] = node
        }

        // Kinder zuweisen
        var childrenByParent: [UUID: [JourneyNode]] = [:]
        var roots: [JourneyNode] = []

        for node in nodes {
            if let parentId = node.parentId {
                childrenByParent[parentId, default: []].append(node)
            } else {
                roots.append(node)
            }
        }

        // Rekursiv Kinder anhängen
        func attachChildren(_ node: JourneyNode) -> JourneyNode {
            var mutableNode = node
            if let children = childrenByParent[node.id] {
                mutableNode.children = children.map { attachChildren($0) }
            }
            return mutableNode
        }

        return roots.map { attachChildren($0) }
    }

    // MARK: - Search

    public func search(query: String, section: JourneySection? = nil) throws -> [JourneyNode] {
        var sql = """
            SELECT * FROM \(JourneySchema.tNodes)
            WHERE (title LIKE ? OR content LIKE ? OR tags LIKE ?)
            """

        if section != nil {
            sql += " AND section = ?"
        }
        sql += " ORDER BY modified_at DESC LIMIT 100"

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            let pattern = "%\(query)%"
            bindText(stmt, 1, pattern)
            bindText(stmt, 2, pattern)
            bindText(stmt, 3, pattern)

            if let section = section {
                bindText(stmt, 4, section.rawValue)
            }

            var nodes: [JourneyNode] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                nodes.append(parseNode(stmt))
            }
            return nodes
        }
    }

    // MARK: - Move Node

    public func moveNode(id: UUID, toParent newParentId: UUID?, sortOrder: Int? = nil) throws {
        var sql = "UPDATE \(JourneySchema.tNodes) SET parent_id = ?, modified_at = ?"
        if sortOrder != nil {
            sql += ", sort_order = ?"
        }
        sql += " WHERE id = ?"

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            var idx: Int32 = 1
            bindUUID(stmt, idx, newParentId)
            idx += 1
            bindDate(stmt, idx, Date())
            idx += 1

            if let sortOrder = sortOrder {
                bindInt(stmt, idx, sortOrder)
                idx += 1
            }

            bindUUID(stmt, idx, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "moveNode")
            }
        }
    }

    // MARK: - Attachment CRUD

    public func insertAttachment(_ attachment: JourneyAttachment) throws {
        let sql = """
            INSERT INTO \(JourneySchema.tAttachments) (
                id, node_id, filename, mime_type, file_size, data_hash, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, attachment.id)
            bindUUID(stmt, 2, attachment.nodeId)
            bindText(stmt, 3, attachment.filename)
            bindText(stmt, 4, attachment.mimeType)
            bindInt64(stmt, 5, attachment.fileSize)
            bindText(stmt, 6, attachment.dataHash)
            bindDate(stmt, 7, attachment.createdAt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "insertAttachment")
            }
        }
    }

    public func deleteAttachment(id: UUID) throws {
        let sql = "DELETE FROM \(JourneySchema.tAttachments) WHERE id = ?"

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "deleteAttachment")
            }
        }
    }

    public func getAttachments(nodeId: UUID) throws -> [JourneyAttachment] {
        let sql = """
            SELECT * FROM \(JourneySchema.tAttachments)
            WHERE node_id = ?
            ORDER BY created_at DESC
            """

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, nodeId)

            var attachments: [JourneyAttachment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                attachments.append(parseAttachment(stmt))
            }
            return attachments
        }
    }

    // MARK: - Contact Ref CRUD

    public func insertContactRef(_ contact: JourneyContactRef) throws {
        let sql = """
            INSERT INTO \(JourneySchema.tContactRefs) (
                id, node_id, contact_id, display_name, email, phone, role, note, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, contact.id)
            bindUUID(stmt, 2, contact.nodeId)
            bindText(stmt, 3, contact.contactId)
            bindText(stmt, 4, contact.displayName)
            bindText(stmt, 5, contact.email)
            bindText(stmt, 6, contact.phone)
            bindText(stmt, 7, contact.role?.rawValue)
            bindText(stmt, 8, contact.note)
            bindDate(stmt, 9, contact.createdAt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "insertContactRef")
            }
        }
    }

    public func deleteContactRef(id: UUID) throws {
        let sql = "DELETE FROM \(JourneySchema.tContactRefs) WHERE id = ?"

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, id)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "deleteContactRef")
            }
        }
    }

    public func getContactRefs(nodeId: UUID) throws -> [JourneyContactRef] {
        let sql = """
            SELECT * FROM \(JourneySchema.tContactRefs)
            WHERE node_id = ?
            ORDER BY created_at DESC
            """

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindUUID(stmt, 1, nodeId)

            var contacts: [JourneyContactRef] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                contacts.append(parseContactRef(stmt))
            }
            return contacts
        }
    }

    // MARK: - Blob CRUD (Deduplicated Media Storage)

    public func insertOrUpdateBlob(_ blob: JourneyBlob) throws {
        // Upsert: Insert or increment ref_count
        let sql = """
            INSERT INTO \(JourneySchema.tBlobs) (hash, data, ref_count)
            VALUES (?, ?, 1)
            ON CONFLICT(hash) DO UPDATE SET ref_count = ref_count + 1
            """

        try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindText(stmt, 1, blob.hash)
            bindBlob(stmt, 2, blob.data)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw dbError(context: "insertOrUpdateBlob")
            }
        }
    }

    public func decrementBlobRef(hash: String) throws {
        // Decrement ref_count, delete if zero
        try dbQueue.sync {
            try ensureOpen()

            // First decrement
            let updateSQL = "UPDATE \(JourneySchema.tBlobs) SET ref_count = ref_count - 1 WHERE hash = ?"
            let updateStmt = try prepare(updateSQL)
            bindText(updateStmt, 1, hash)
            _ = sqlite3_step(updateStmt)
            finalize(updateStmt)

            // Then delete if zero
            let deleteSQL = "DELETE FROM \(JourneySchema.tBlobs) WHERE hash = ? AND ref_count <= 0"
            let deleteStmt = try prepare(deleteSQL)
            bindText(deleteStmt, 1, hash)
            _ = sqlite3_step(deleteStmt)
            finalize(deleteStmt)
        }
    }

    public func getBlob(hash: String) throws -> JourneyBlob? {
        let sql = "SELECT * FROM \(JourneySchema.tBlobs) WHERE hash = ?"

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            bindText(stmt, 1, hash)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }

            return JourneyBlob(
                hash: stmt.columnText(0) ?? "",
                data: stmt.columnBlob(1) ?? Data(),
                refCount: stmt.columnInt(2)
            )
        }
    }

    // MARK: - Batch Sort Order Update

    /// Aktualisiert sortOrder für mehrere Nodes (nach Drag & Drop Reorder)
    public func updateSortOrders(_ updates: [(id: UUID, sortOrder: Int)]) throws {
        try dbQueue.sync {
            try ensureOpen()

            let sql = "UPDATE \(JourneySchema.tNodes) SET sort_order = ?, modified_at = ? WHERE id = ?"
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            let now = Date()

            for update in updates {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                bindInt(stmt, 1, update.sortOrder)
                bindDate(stmt, 2, now)
                bindUUID(stmt, 3, update.id)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw dbError(context: "updateSortOrders")
                }
            }
        }
    }

    /// Gibt maximale sortOrder für einen Parent zurück
    public func getMaxSortOrder(parentId: UUID?) throws -> Int {
        let sql: String
        if parentId != nil {
            sql = "SELECT MAX(sort_order) FROM \(JourneySchema.tNodes) WHERE parent_id = ?"
        } else {
            sql = "SELECT MAX(sort_order) FROM \(JourneySchema.tNodes) WHERE parent_id IS NULL"
        }

        return try dbQueue.sync {
            try ensureOpen()
            let stmt = try prepare(sql)
            defer { finalize(stmt) }

            if let parentId = parentId {
                bindUUID(stmt, 1, parentId)
            }

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return 0
            }

            return stmt.columnInt(0)
        }
    }

    // MARK: - Helpers

    private func bindTagsJSON(_ statement: OpaquePointer, _ index: Int32, _ tags: [String]) {
        if tags.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let json = (try? JSONEncoder().encode(tags)).flatMap { String(data: $0, encoding: .utf8) }
            bindText(statement, index, json)
        }
    }

    private func parseTagsJSON(_ jsonString: String?) -> [String] {
        guard let jsonString = jsonString,
              let data = jsonString.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return tags
    }

    private func parseNode(_ stmt: OpaquePointer) -> JourneyNode {
        // Column order: id, origin_id, revision, parent_id, section, node_type, title, content,
        //               sort_order, tags, created_at, modified_at, doing_at,
        //               status, due_date, progress, calendar_event_id,
        //               assigned_to, created_by, completed_at, completed_by
        JourneyNode(
            id: stmt.columnUUID(0) ?? UUID(),
            originId: stmt.columnUUID(1),
            revision: stmt.columnInt(2),
            parentId: stmt.columnUUID(3),
            section: JourneySection(rawValue: stmt.columnText(4) ?? "") ?? .inbox,
            nodeType: JourneyNodeType(rawValue: stmt.columnText(5) ?? "") ?? .entry,
            title: stmt.columnText(6) ?? "",
            content: stmt.columnText(7),
            sortOrder: stmt.columnInt(8),
            tags: parseTagsJSON(stmt.columnText(9)),
            createdAt: stmt.columnDate(10) ?? Date(),
            modifiedAt: stmt.columnDate(11) ?? Date(),
            doingAt: stmt.columnDate(12),
            status: stmt.columnText(13).flatMap { JourneyTaskStatus(rawValue: $0) },
            dueDate: stmt.columnDate(14),
            progress: stmt.columnIsNull(15) ? nil : stmt.columnInt(15),
            calendarEventId: stmt.columnText(16),
            assignedTo: stmt.columnUUID(17),
            createdBy: stmt.columnUUID(18),
            completedAt: stmt.columnDate(19),
            completedBy: stmt.columnUUID(20)
        )
    }

    private func parseAttachment(_ stmt: OpaquePointer) -> JourneyAttachment {
        // Column order: id, node_id, filename, mime_type, file_size, data_hash, created_at
        JourneyAttachment(
            id: stmt.columnUUID(0) ?? UUID(),
            nodeId: stmt.columnUUID(1) ?? UUID(),
            filename: stmt.columnText(2) ?? "",
            mimeType: stmt.columnText(3) ?? "",
            fileSize: stmt.columnInt64(4),
            dataHash: stmt.columnText(5) ?? "",
            createdAt: stmt.columnDate(6) ?? Date()
        )
    }

    private func parseContactRef(_ stmt: OpaquePointer) -> JourneyContactRef {
        // Column order: id, node_id, contact_id, display_name, email, phone, role, note, created_at
        JourneyContactRef(
            id: stmt.columnUUID(0) ?? UUID(),
            nodeId: stmt.columnUUID(1) ?? UUID(),
            contactId: stmt.columnText(2),
            displayName: stmt.columnText(3) ?? "",
            email: stmt.columnText(4),
            phone: stmt.columnText(5),
            role: stmt.columnText(6).flatMap { ContactRole(rawValue: $0) },
            note: stmt.columnText(7),
            createdAt: stmt.columnDate(8) ?? Date()
        )
    }
}
