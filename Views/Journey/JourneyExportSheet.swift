// Views/Journey/JourneyExportSheet.swift
// Journey Feature - Export Sheet UI

import SwiftUI
import UniformTypeIdentifiers

struct JourneyExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JourneyStore

    let nodes: [JourneyNode]
    let exportMode: ExportMode

    @State private var includeAttachments = true
    @State private var includeContacts = true
    @State private var includeSubnodes = true
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var showingExporter = false
    @State private var exportData: Data?

    enum ExportMode {
        case selectedNodes([JourneyNode])
        case section(JourneySection)
        case all

        var title: String {
            switch self {
            case .selectedNodes(let nodes):
                if nodes.count == 1 {
                    return nodes.first?.title ?? String(localized: "journey.export.title.node")
                } else {
                    return String(localized: "journey.export.title.nodes \(nodes.count)")
                }
            case .section(let section):
                return section.title
            case .all:
                return String(localized: "journey.export.title.all")
            }
        }
    }

    init(nodes: [JourneyNode]) {
        self.nodes = nodes
        self.exportMode = .selectedNodes(nodes)
    }

    init(section: JourneySection) {
        self.nodes = []
        self.exportMode = .section(section)
    }

    init() {
        self.nodes = []
        self.exportMode = .all
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(exportMode.title)
                                .font(.headline)
                            Text(String(localized: "journey.export.format"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section(header: Text(String(localized: "journey.export.options"))) {
                    Toggle(String(localized: "journey.export.includeSubnodes"), isOn: $includeSubnodes)
                    Toggle(String(localized: "journey.export.includeAttachments"), isOn: $includeAttachments)
                    Toggle(String(localized: "journey.export.includeContacts"), isOn: $includeContacts)
                }

                if let error = exportError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "journey.export.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "journey.export.action")) {
                        performExport()
                    }
                    .disabled(isExporting)
                }
            }
            .overlay {
                if isExporting {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportData.map { AILOExportDocument(data: $0) },
                contentType: .ailoExport,
                defaultFilename: defaultFilename
            ) { result in
                switch result {
                case .success:
                    dismiss()
                case .failure(let error):
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private var defaultFilename: String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        switch exportMode {
        case .selectedNodes(let nodes):
            if nodes.count == 1, let node = nodes.first {
                return "\(node.title)_\(dateString)"
            } else {
                return "AILO_Export_\(dateString)"
            }
        case .section(let section):
            return "\(section.title)_\(dateString)"
        case .all:
            return "AILO_Backup_\(dateString)"
        }
    }

    private func performExport() {
        isExporting = true
        exportError = nil

        Task {
            do {
                guard let dao = store.dao else {
                    throw ExportError.daoNotAvailable
                }

                let service = JourneyExportService(dao: dao)
                let options = JourneyExportOptions(
                    includeAttachments: includeAttachments,
                    includeContacts: includeContacts,
                    includeSubnodes: includeSubnodes
                )

                let data: Data
                switch exportMode {
                case .selectedNodes(let nodes):
                    data = try service.exportNodes(nodes, options: options)
                case .section(let section):
                    data = try service.exportSection(section, options: options)
                case .all:
                    data = try service.exportAll(options: options)
                }

                await MainActor.run {
                    exportData = data
                    isExporting = false
                    showingExporter = true
                }
            } catch {
                await MainActor.run {
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    enum ExportError: Error, LocalizedError {
        case daoNotAvailable

        var errorDescription: String? {
            switch self {
            case .daoNotAvailable:
                return String(localized: "journey.export.error.daoNotAvailable")
            }
        }
    }
}
