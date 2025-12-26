// Services/JourneyExportDocument.swift
// Journey Feature - Export/Import Document Models

import Foundation
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Export Manifest

public struct JourneyExportManifest: Codable {
    public var version: Int
    public var exportedAt: Date
    public var deviceId: String
    public var appVersion: String
    public var nodeCount: Int
    public var attachmentCount: Int
    public var contactCount: Int
    public var blobCount: Int

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        deviceId: String = "",
        appVersion: String = "",
        nodeCount: Int = 0,
        attachmentCount: Int = 0,
        contactCount: Int = 0,
        blobCount: Int = 0
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.nodeCount = nodeCount
        self.attachmentCount = attachmentCount
        self.contactCount = contactCount
        self.blobCount = blobCount
    }
}

// MARK: - Export Container

public struct JourneyExportContainer: Codable {
    public var manifest: JourneyExportManifest
    public var nodes: [JourneyNode]
    public var attachments: [JourneyAttachment]
    public var contacts: [JourneyContactRef]
    public var blobHashes: [String]

    public init(
        manifest: JourneyExportManifest,
        nodes: [JourneyNode],
        attachments: [JourneyAttachment],
        contacts: [JourneyContactRef],
        blobHashes: [String]
    ) {
        self.manifest = manifest
        self.nodes = nodes
        self.attachments = attachments
        self.contacts = contacts
        self.blobHashes = blobHashes
    }
}

// MARK: - Import Conflict Detection

public enum ImportConflictType: Equatable, Sendable {
    case sameOriginNewerRevision
    case sameOriginOlderRevision
    case sameOriginSameRevision
    case noConflict
}

public struct ImportConflictInfo: Identifiable, Sendable {
    public var id: UUID { importNode.id }
    public var importNode: JourneyNode
    public var existingNode: JourneyNode?
    public var conflictType: ImportConflictType

    public init(importNode: JourneyNode, existingNode: JourneyNode?, conflictType: ImportConflictType) {
        self.importNode = importNode
        self.existingNode = existingNode
        self.conflictType = conflictType
    }
}

public enum ImportConflictResolution: Sendable {
    case skip
    case overwrite
    case keepBoth
}

// MARK: - Import Result

public struct JourneyImportResult: Sendable {
    public var importedNodes: Int
    public var skippedNodes: Int
    public var importedAttachments: Int
    public var importedContacts: Int
    public var importedBlobs: Int
    public var errors: [String]

    public init(
        importedNodes: Int = 0,
        skippedNodes: Int = 0,
        importedAttachments: Int = 0,
        importedContacts: Int = 0,
        importedBlobs: Int = 0,
        errors: [String] = []
    ) {
        self.importedNodes = importedNodes
        self.skippedNodes = skippedNodes
        self.importedAttachments = importedAttachments
        self.importedContacts = importedContacts
        self.importedBlobs = importedBlobs
        self.errors = errors
    }
}

// MARK: - Export Options

public struct JourneyExportOptions {
    public var includeAttachments: Bool
    public var includeContacts: Bool
    public var includeSubnodes: Bool
    public var selectedNodeIds: Set<UUID>

    public init(
        includeAttachments: Bool = true,
        includeContacts: Bool = true,
        includeSubnodes: Bool = true,
        selectedNodeIds: Set<UUID> = []
    ) {
        self.includeAttachments = includeAttachments
        self.includeContacts = includeContacts
        self.includeSubnodes = includeSubnodes
        self.selectedNodeIds = selectedNodeIds
    }
}

// MARK: - SwiftUI FileDocument

public struct AILOExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.ailoExport] }
    public static var writableContentTypes: [UTType] { [.ailoExport] }

    public var data: Data

    public init(data: Data = Data()) {
        self.data = data
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
