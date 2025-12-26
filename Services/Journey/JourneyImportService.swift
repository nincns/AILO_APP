// Services/JourneyImportService.swift
// Journey Feature - Import Service for .ailo files

import Foundation

public final class JourneyImportService: @unchecked Sendable {

    private let dao: JourneyDAO
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(dao: JourneyDAO) {
        self.dao = dao
    }

    // MARK: - Parse Archive

    public func parseArchive(_ data: Data) throws -> JourneyExportContainer {
        let zipReader = ZipReader(data: data)
        let files = try zipReader.readAllFiles()

        guard let manifestData = files["manifest.json"] else {
            throw ImportError.missingManifest
        }
        let manifest = try decoder.decode(JourneyExportManifest.self, from: manifestData)

        guard let nodesData = files["nodes.json"] else {
            throw ImportError.missingNodes
        }
        let nodes = try decoder.decode([JourneyNode].self, from: nodesData)

        var attachments: [JourneyAttachment] = []
        if let attachmentsData = files["attachments.json"] {
            attachments = try decoder.decode([JourneyAttachment].self, from: attachmentsData)
        }

        var contacts: [JourneyContactRef] = []
        if let contactsData = files["contacts.json"] {
            contacts = try decoder.decode([JourneyContactRef].self, from: contactsData)
        }

        var blobHashes: [String] = []
        for key in files.keys where key.hasPrefix("blobs/") {
            let hash = String(key.dropFirst("blobs/".count))
            if !hash.isEmpty {
                blobHashes.append(hash)
            }
        }

        return JourneyExportContainer(
            manifest: manifest,
            nodes: nodes,
            attachments: attachments,
            contacts: contacts,
            blobHashes: blobHashes
        )
    }

    // MARK: - Detect Conflicts

    public func detectConflicts(in container: JourneyExportContainer) throws -> [ImportConflictInfo] {
        var conflicts: [ImportConflictInfo] = []

        for importNode in container.nodes {
            let existingNode = try dao.getNodeByOriginId(importNode.originId)

            if let existing = existingNode {
                let conflictType: ImportConflictType
                if importNode.revision > existing.revision {
                    conflictType = .sameOriginNewerRevision
                } else if importNode.revision < existing.revision {
                    conflictType = .sameOriginOlderRevision
                } else {
                    conflictType = .sameOriginSameRevision
                }
                conflicts.append(ImportConflictInfo(
                    importNode: importNode,
                    existingNode: existing,
                    conflictType: conflictType
                ))
            } else {
                conflicts.append(ImportConflictInfo(
                    importNode: importNode,
                    existingNode: nil,
                    conflictType: .noConflict
                ))
            }
        }

        return conflicts
    }

    // MARK: - Import with Resolution

    public func importArchive(
        _ data: Data,
        resolutions: [UUID: ImportConflictResolution] = [:],
        defaultResolution: ImportConflictResolution = .keepBoth
    ) throws -> JourneyImportResult {
        let container = try parseArchive(data)
        let zipReader = ZipReader(data: data)
        let files = try zipReader.readAllFiles()

        var result = JourneyImportResult()
        var idMapping: [UUID: UUID] = [:]

        // Sort nodes by hierarchy: parents before children
        let sortedNodes = sortNodesByHierarchy(container.nodes)

        // Import nodes in correct order
        for importNode in sortedNodes {
            let resolution = resolutions[importNode.id] ?? defaultResolution
            let existingNode = try dao.getNodeByOriginId(importNode.originId)

            // Map parent ID if parent was already imported with new ID
            var nodeToImport = importNode

            if let oldParentId = importNode.parentId {
                if let newParentId = idMapping[oldParentId] {
                    // Parent was imported with new ID
                    nodeToImport.parentId = newParentId
                } else if try dao.getNode(id: oldParentId) == nil {
                    // Parent doesn't exist in DB and wasn't imported - fallback to Inbox
                    nodeToImport.parentId = nil
                    nodeToImport.section = .inbox
                    print("⚠️ Import: Node '\(importNode.title)' orphaned, placing in Inbox")
                }
            }

            do {
                switch resolution {
                case .skip:
                    result.skippedNodes += 1

                case .overwrite:
                    if let existing = existingNode {
                        var updated = nodeToImport
                        updated.id = existing.id
                        updated.revision = importNode.revision
                        try dao.updateNode(updated)
                        idMapping[importNode.id] = existing.id
                        result.importedNodes += 1
                    } else {
                        try insertNodeSafely(&nodeToImport, idMapping: &idMapping, result: &result)
                    }

                case .keepBoth:
                    if existingNode != nil {
                        var newNode = nodeToImport
                        newNode.id = UUID()
                        newNode.title = "\(importNode.title) (importiert)"
                        try insertNodeSafely(&newNode, idMapping: &idMapping, result: &result, originalId: importNode.id)
                    } else {
                        try insertNodeSafely(&nodeToImport, idMapping: &idMapping, result: &result)
                    }
                }
            } catch {
                result.errors.append("Node \(importNode.title): \(error.localizedDescription)")
            }
        }

        // Import blobs
        for hash in container.blobHashes {
            if let blobData = files["blobs/\(hash)"] {
                do {
                    let blob = JourneyBlob(hash: hash, data: blobData, refCount: 1)
                    try dao.insertOrUpdateBlob(blob)
                    result.importedBlobs += 1
                } catch {
                    result.errors.append("Blob \(hash): \(error.localizedDescription)")
                }
            }
        }

        // Import attachments
        for attachment in container.attachments {
            if let newNodeId = idMapping[attachment.nodeId] {
                do {
                    var newAttachment = attachment
                    newAttachment.id = UUID()
                    newAttachment.nodeId = newNodeId
                    try dao.insertAttachment(newAttachment)
                    result.importedAttachments += 1
                } catch {
                    result.errors.append("Attachment \(attachment.filename): \(error.localizedDescription)")
                }
            }
        }

        // Import contacts
        for contact in container.contacts {
            if let newNodeId = idMapping[contact.nodeId] {
                do {
                    var newContact = contact
                    newContact.id = UUID()
                    newContact.nodeId = newNodeId
                    try dao.insertContactRef(newContact)
                    result.importedContacts += 1
                } catch {
                    result.errors.append("Contact \(contact.displayName): \(error.localizedDescription)")
                }
            }
        }

        return result
    }

    // MARK: - Private Helpers

    /// Inserts a node, with fallback to Inbox if parent doesn't exist
    private func insertNodeSafely(
        _ node: inout JourneyNode,
        idMapping: inout [UUID: UUID],
        result: inout JourneyImportResult,
        originalId: UUID? = nil
    ) throws {
        let nodeId = originalId ?? node.id

        do {
            try dao.insertNode(node)
            idMapping[nodeId] = node.id
            result.importedNodes += 1
        } catch {
            // Check if it's a FOREIGN KEY constraint error
            let errorString = String(describing: error)
            if errorString.contains("FOREIGN KEY") || errorString.contains("constraint") {
                // Fallback: place in Inbox as root node
                print("⚠️ Import: Node '\(node.title)' FOREIGN KEY failed, placing in Inbox")
                node.parentId = nil
                node.section = .inbox

                // Retry insert
                try dao.insertNode(node)
                idMapping[nodeId] = node.id
                result.importedNodes += 1
            } else {
                throw error
            }
        }
    }

    /// Sorts nodes so that parent nodes come before their children
    private func sortNodesByHierarchy(_ nodes: [JourneyNode]) -> [JourneyNode] {
        var sorted: [JourneyNode] = []
        var remaining = nodes
        var nodeIds = Set(nodes.map { $0.id })

        // First pass: add all root nodes (no parent or parent not in import)
        var i = 0
        while i < remaining.count {
            let node = remaining[i]
            if node.parentId == nil || !nodeIds.contains(node.parentId!) {
                sorted.append(node)
                remaining.remove(at: i)
            } else {
                i += 1
            }
        }

        // Subsequent passes: add nodes whose parents are already in sorted
        var sortedIds = Set(sorted.map { $0.id })
        var maxIterations = remaining.count + 1 // Prevent infinite loop

        while !remaining.isEmpty && maxIterations > 0 {
            maxIterations -= 1
            var addedAny = false

            i = 0
            while i < remaining.count {
                let node = remaining[i]
                if let parentId = node.parentId, sortedIds.contains(parentId) {
                    sorted.append(node)
                    sortedIds.insert(node.id)
                    remaining.remove(at: i)
                    addedAny = true
                } else {
                    i += 1
                }
            }

            // If no progress, break to avoid infinite loop
            if !addedAny {
                // Add remaining nodes anyway (orphans)
                sorted.append(contentsOf: remaining)
                break
            }
        }

        return sorted
    }

    // MARK: - Errors

    public enum ImportError: Error, LocalizedError {
        case missingManifest
        case missingNodes
        case invalidArchive
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .missingManifest:
                return String(localized: "journey.import.error.missingManifest")
            case .missingNodes:
                return String(localized: "journey.import.error.missingNodes")
            case .invalidArchive:
                return String(localized: "journey.import.error.invalidArchive")
            case .unsupportedVersion(let version):
                return String(localized: "journey.import.error.unsupportedVersion \(version)")
            }
        }
    }
}

// MARK: - Simple ZIP Reader

private struct ZipReader {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func readAllFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        var offset = 0

        while offset < data.count - 4 {
            let signature = readUInt32(at: offset)

            if signature == 0x04034B50 { // Local file header
                let compressedSize = Int(readUInt32(at: offset + 18))
                let uncompressedSize = Int(readUInt32(at: offset + 22))
                let fileNameLength = Int(readUInt16(at: offset + 26))
                let extraFieldLength = Int(readUInt16(at: offset + 28))

                let nameStart = offset + 30
                let nameEnd = nameStart + fileNameLength
                guard nameEnd <= data.count else { break }

                let nameData = data[nameStart..<nameEnd]
                guard let fileName = String(data: nameData, encoding: .utf8) else {
                    offset = nameEnd + extraFieldLength + compressedSize
                    continue
                }

                let dataStart = nameEnd + extraFieldLength
                let dataEnd = dataStart + compressedSize

                guard dataEnd <= data.count else { break }

                let compressionMethod = readUInt16(at: offset + 8)
                if compressionMethod == 0 { // Store (no compression)
                    files[fileName] = data[dataStart..<dataEnd]
                }

                offset = dataEnd

            } else if signature == 0x02014B50 { // Central directory
                break
            } else if signature == 0x06054B50 { // End of central directory
                break
            } else {
                offset += 1
            }
        }

        return files
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) |
               (UInt32(data[offset + 1]) << 8) |
               (UInt32(data[offset + 2]) << 16) |
               (UInt32(data[offset + 3]) << 24)
    }
}
