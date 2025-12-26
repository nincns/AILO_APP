// Services/JourneyExportService.swift
// Journey Feature - Export Service for .ailo files

import Foundation
import Compression

public final class JourneyExportService: @unchecked Sendable {

    private let dao: JourneyDAO
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    public init(dao: JourneyDAO) {
        self.dao = dao
    }

    // MARK: - Export Single Node

    public func exportNode(_ node: JourneyNode, options: JourneyExportOptions = JourneyExportOptions()) throws -> Data {
        var nodesToExport: [JourneyNode] = [node]

        if options.includeSubnodes {
            let children = try collectAllChildren(of: node.id)
            nodesToExport.append(contentsOf: children)
        }

        return try exportNodes(nodesToExport, options: options)
    }

    // MARK: - Export Multiple Nodes

    public func exportNodes(_ nodes: [JourneyNode], options: JourneyExportOptions = JourneyExportOptions()) throws -> Data {
        var allNodes = nodes

        if options.includeSubnodes {
            for node in nodes {
                let children = try collectAllChildren(of: node.id)
                for child in children {
                    if !allNodes.contains(where: { $0.id == child.id }) {
                        allNodes.append(child)
                    }
                }
            }
        }

        var attachments: [JourneyAttachment] = []
        var contacts: [JourneyContactRef] = []
        var blobHashes: Set<String> = []

        if options.includeAttachments {
            for node in allNodes {
                let nodeAttachments = try dao.getAttachments(nodeId: node.id)
                attachments.append(contentsOf: nodeAttachments)
                for att in nodeAttachments {
                    blobHashes.insert(att.dataHash)
                }
            }
        }

        if options.includeContacts {
            for node in allNodes {
                let nodeContacts = try dao.getContactRefs(nodeId: node.id)
                contacts.append(contentsOf: nodeContacts)
            }
        }

        let manifest = JourneyExportManifest(
            version: 1,
            exportedAt: Date(),
            deviceId: deviceIdentifier(),
            appVersion: appVersion(),
            nodeCount: allNodes.count,
            attachmentCount: attachments.count,
            contactCount: contacts.count,
            blobCount: blobHashes.count
        )

        return try createZipArchive(
            manifest: manifest,
            nodes: allNodes,
            attachments: attachments,
            contacts: contacts,
            blobHashes: Array(blobHashes)
        )
    }

    // MARK: - Export Section

    public func exportSection(_ section: JourneySection, options: JourneyExportOptions = JourneyExportOptions()) throws -> Data {
        let nodes = try dao.getRootNodes(section: section)
        var allNodes: [JourneyNode] = []

        for node in nodes {
            allNodes.append(node)
            if options.includeSubnodes {
                let children = try collectAllChildren(of: node.id)
                allNodes.append(contentsOf: children)
            }
        }

        return try exportNodes(allNodes, options: options)
    }

    // MARK: - Export All

    public func exportAll(options: JourneyExportOptions = JourneyExportOptions()) throws -> Data {
        var allNodes: [JourneyNode] = []

        for section in JourneySection.allCases {
            let nodes = try dao.getRootNodes(section: section)
            for node in nodes {
                allNodes.append(node)
                if options.includeSubnodes {
                    let children = try collectAllChildren(of: node.id)
                    allNodes.append(contentsOf: children)
                }
            }
        }

        return try exportNodes(allNodes, options: options)
    }

    // MARK: - Private Helpers

    private func collectAllChildren(of nodeId: UUID) throws -> [JourneyNode] {
        var result: [JourneyNode] = []
        let directChildren = try dao.getChildren(parentId: nodeId)

        for child in directChildren {
            result.append(child)
            let grandChildren = try collectAllChildren(of: child.id)
            result.append(contentsOf: grandChildren)
        }

        return result
    }

    private func deviceIdentifier() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #else
        return Host.current().localizedName ?? "unknown"
        #endif
    }

    private func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - ZIP Archive Creation

    private func createZipArchive(
        manifest: JourneyExportManifest,
        nodes: [JourneyNode],
        attachments: [JourneyAttachment],
        contacts: [JourneyContactRef],
        blobHashes: [String]
    ) throws -> Data {
        var zipBuilder = ZipBuilder()

        // manifest.json
        let manifestData = try encoder.encode(manifest)
        zipBuilder.addFile(name: "manifest.json", data: manifestData)

        // nodes.json
        let nodesData = try encoder.encode(nodes)
        zipBuilder.addFile(name: "nodes.json", data: nodesData)

        // attachments.json
        let attachmentsData = try encoder.encode(attachments)
        zipBuilder.addFile(name: "attachments.json", data: attachmentsData)

        // contacts.json
        let contactsData = try encoder.encode(contacts)
        zipBuilder.addFile(name: "contacts.json", data: contactsData)

        // blobs/
        for hash in blobHashes {
            if let blob = try dao.getBlob(hash: hash) {
                zipBuilder.addFile(name: "blobs/\(hash)", data: blob.data)
            }
        }

        return zipBuilder.finalize()
    }
}

// MARK: - Simple ZIP Builder (Store Mode)

private struct ZipBuilder {
    private var files: [(name: String, data: Data)] = []

    mutating func addFile(name: String, data: Data) {
        files.append((name: name, data: data))
    }

    func finalize() -> Data {
        var centralDirectory = Data()
        var fileData = Data()
        var centralDirectoryOffset: UInt32 = 0

        for file in files {
            let localHeader = createLocalFileHeader(name: file.name, data: file.data)
            let centralHeader = createCentralDirectoryHeader(
                name: file.name,
                data: file.data,
                localHeaderOffset: centralDirectoryOffset
            )

            fileData.append(localHeader)
            fileData.append(file.data)
            centralDirectory.append(centralHeader)

            centralDirectoryOffset = UInt32(fileData.count)
        }

        let endOfCentralDirectory = createEndOfCentralDirectory(
            entryCount: UInt16(files.count),
            centralDirectorySize: UInt32(centralDirectory.count),
            centralDirectoryOffset: UInt32(fileData.count)
        )

        var result = Data()
        result.append(fileData)
        result.append(centralDirectory)
        result.append(endOfCentralDirectory)

        return result
    }

    private func createLocalFileHeader(name: String, data: Data) -> Data {
        let nameData = Data(name.utf8)
        let crc = crc32(data)
        let size = UInt32(data.count)

        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // Local file header signature
        header.append(contentsOf: UInt16(20).littleEndianBytes) // Version needed
        header.append(contentsOf: UInt16(0).littleEndianBytes) // General purpose bit flag
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Compression method (store)
        header.append(contentsOf: UInt16(0).littleEndianBytes) // File time
        header.append(contentsOf: UInt16(0).littleEndianBytes) // File date
        header.append(contentsOf: crc.littleEndianBytes) // CRC-32
        header.append(contentsOf: size.littleEndianBytes) // Compressed size
        header.append(contentsOf: size.littleEndianBytes) // Uncompressed size
        header.append(contentsOf: UInt16(nameData.count).littleEndianBytes) // File name length
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Extra field length
        header.append(nameData) // File name

        return header
    }

    private func createCentralDirectoryHeader(name: String, data: Data, localHeaderOffset: UInt32) -> Data {
        let nameData = Data(name.utf8)
        let crc = crc32(data)
        let size = UInt32(data.count)

        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // Central directory header signature
        header.append(contentsOf: UInt16(20).littleEndianBytes) // Version made by
        header.append(contentsOf: UInt16(20).littleEndianBytes) // Version needed
        header.append(contentsOf: UInt16(0).littleEndianBytes) // General purpose bit flag
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Compression method (store)
        header.append(contentsOf: UInt16(0).littleEndianBytes) // File time
        header.append(contentsOf: UInt16(0).littleEndianBytes) // File date
        header.append(contentsOf: crc.littleEndianBytes) // CRC-32
        header.append(contentsOf: size.littleEndianBytes) // Compressed size
        header.append(contentsOf: size.littleEndianBytes) // Uncompressed size
        header.append(contentsOf: UInt16(nameData.count).littleEndianBytes) // File name length
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Extra field length
        header.append(contentsOf: UInt16(0).littleEndianBytes) // File comment length
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Disk number start
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Internal file attributes
        header.append(contentsOf: UInt32(0).littleEndianBytes) // External file attributes
        header.append(contentsOf: localHeaderOffset.littleEndianBytes) // Relative offset of local header
        header.append(nameData) // File name

        return header
    }

    private func createEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var header = Data()
        header.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // End of central directory signature
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Number of this disk
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Disk where central directory starts
        header.append(contentsOf: entryCount.littleEndianBytes) // Number of central directory records on this disk
        header.append(contentsOf: entryCount.littleEndianBytes) // Total number of central directory records
        header.append(contentsOf: centralDirectorySize.littleEndianBytes) // Size of central directory
        header.append(contentsOf: centralDirectoryOffset.littleEndianBytes) // Offset of start of central directory
        header.append(contentsOf: UInt16(0).littleEndianBytes) // Comment length

        return header
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        let table = makeCRC32Table()

        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }

        return crc ^ 0xFFFFFFFF
    }

    private func makeCRC32Table() -> [UInt32] {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }
}

// MARK: - Little Endian Helpers

private extension UInt16 {
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }
}
