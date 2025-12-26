// Views/Journey/JourneyImportSheet.swift
// Journey Feature - Import Sheet UI with Conflict Resolution

import SwiftUI
import UniformTypeIdentifiers

struct JourneyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JourneyStore

    let fileURL: URL?

    @State private var importData: Data?
    @State private var container: JourneyExportContainer?
    @State private var conflicts: [ImportConflictInfo] = []
    @State private var resolutions: [UUID: ImportConflictResolution] = [:]
    @State private var defaultResolution: ImportConflictResolution = .keepBoth
    @State private var isLoading = false
    @State private var isImporting = false
    @State private var importResult: JourneyImportResult?
    @State private var errorMessage: String?
    @State private var showingFilePicker = false

    init(url: URL? = nil) {
        self.fileURL = url
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    loadingView
                } else if let result = importResult {
                    resultView(result)
                } else if let container = container {
                    conflictResolutionView(container)
                } else {
                    selectFileView
                }
            }
            .navigationTitle(String(localized: "journey.import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.ailoExport],
                allowsMultipleSelection: false
            ) { result in
                handleFileSelection(result)
            }
        }
        .onAppear {
            if let url = fileURL {
                loadFile(from: url)
            }
        }
    }

    // MARK: - Views

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text(String(localized: "journey.import.loading"))
                .foregroundStyle(.secondary)
        }
    }

    private var selectFileView: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text(String(localized: "journey.import.selectFile"))
                .font(.headline)

            Button(action: { showingFilePicker = true }) {
                Label(String(localized: "journey.import.chooseFile"), systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .padding()
    }

    private func conflictResolutionView(_ container: JourneyExportContainer) -> some View {
        Form {
            Section {
                manifestInfoView(container.manifest)
            }

            if hasConflicts {
                Section(header: Text(String(localized: "journey.import.conflictResolution"))) {
                    Picker(String(localized: "journey.import.defaultAction"), selection: $defaultResolution) {
                        Text(String(localized: "journey.import.resolution.keepBoth")).tag(ImportConflictResolution.keepBoth)
                        Text(String(localized: "journey.import.resolution.overwrite")).tag(ImportConflictResolution.overwrite)
                        Text(String(localized: "journey.import.resolution.skip")).tag(ImportConflictResolution.skip)
                    }
                }

                Section(header: Text(String(localized: "journey.import.conflicts \(conflictCount)"))) {
                    ForEach(conflictsWithIssues) { conflict in
                        conflictRow(conflict)
                    }
                }
            }

            Section {
                Button(action: performImport) {
                    HStack {
                        Spacer()
                        if isImporting {
                            ProgressView()
                        } else {
                            Text(String(localized: "journey.import.action"))
                        }
                        Spacer()
                    }
                }
                .disabled(isImporting)
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func manifestInfoView(_ manifest: JourneyExportManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.zipper")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(String(localized: "journey.import.archiveInfo"))
                        .font(.headline)
                    Text(manifest.exportedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Label("\(manifest.nodeCount)", systemImage: "doc.text")
                Spacer()
                Label("\(manifest.attachmentCount)", systemImage: "paperclip")
                Spacer()
                Label("\(manifest.contactCount)", systemImage: "person")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func conflictRow(_ conflict: ImportConflictInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: conflict.importNode.nodeType.icon)
                    .foregroundStyle(conflictColor(conflict.conflictType))
                Text(conflict.importNode.title)
                    .lineLimit(1)
                Spacer()
                conflictBadge(conflict.conflictType)
            }

            if let existing = conflict.existingNode {
                HStack {
                    Text(String(localized: "journey.import.existingRevision \(existing.revision)"))
                    Text("vs")
                    Text(String(localized: "journey.import.importRevision \(conflict.importNode.revision)"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(
                get: { resolutions[conflict.importNode.id] ?? defaultResolution },
                set: { resolutions[conflict.importNode.id] = $0 }
            )) {
                Text(String(localized: "journey.import.resolution.keepBoth.short")).tag(ImportConflictResolution.keepBoth)
                Text(String(localized: "journey.import.resolution.overwrite.short")).tag(ImportConflictResolution.overwrite)
                Text(String(localized: "journey.import.resolution.skip.short")).tag(ImportConflictResolution.skip)
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    private func conflictBadge(_ type: ImportConflictType) -> some View {
        Text(conflictLabel(type))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(conflictColor(type).opacity(0.2))
            .foregroundStyle(conflictColor(type))
            .clipShape(Capsule())
    }

    private func resultView(_ result: JourneyImportResult) -> some View {
        VStack(spacing: 24) {
            Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(result.errors.isEmpty ? .green : .orange)

            Text(result.errors.isEmpty ?
                 String(localized: "journey.import.success") :
                 String(localized: "journey.import.partial"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                resultRow(icon: "doc.text", label: String(localized: "journey.import.result.nodes"), value: result.importedNodes)
                if result.skippedNodes > 0 {
                    resultRow(icon: "arrow.uturn.right", label: String(localized: "journey.import.result.skipped"), value: result.skippedNodes)
                }
                resultRow(icon: "paperclip", label: String(localized: "journey.import.result.attachments"), value: result.importedAttachments)
                resultRow(icon: "person", label: String(localized: "journey.import.result.contacts"), value: result.importedContacts)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            if !result.errors.isEmpty {
                VStack(alignment: .leading) {
                    Text(String(localized: "journey.import.errors"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(result.errors.prefix(5), id: \.self) { error in
                        Text("- \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Button(String(localized: "common.done")) {
                Task {
                    await store.loadAllSections()
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func resultRow(icon: String, label: String, value: Int) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text("\(value)")
                .fontWeight(.medium)
        }
    }

    // MARK: - Helpers

    private var hasConflicts: Bool {
        conflicts.contains { $0.conflictType != .noConflict }
    }

    private var conflictCount: Int {
        conflicts.filter { $0.conflictType != .noConflict }.count
    }

    private var conflictsWithIssues: [ImportConflictInfo] {
        conflicts.filter { $0.conflictType != .noConflict }
    }

    private func conflictLabel(_ type: ImportConflictType) -> String {
        switch type {
        case .sameOriginNewerRevision:
            return String(localized: "journey.import.conflict.newer")
        case .sameOriginOlderRevision:
            return String(localized: "journey.import.conflict.older")
        case .sameOriginSameRevision:
            return String(localized: "journey.import.conflict.same")
        case .noConflict:
            return ""
        }
    }

    private func conflictColor(_ type: ImportConflictType) -> Color {
        switch type {
        case .sameOriginNewerRevision:
            return .green
        case .sameOriginOlderRevision:
            return .orange
        case .sameOriginSameRevision:
            return .blue
        case .noConflict:
            return .gray
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                loadFile(from: url)
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func loadFile(from url: URL) {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let data = try Data(contentsOf: url)

                guard let dao = store.dao else {
                    throw JourneyImportService.ImportError.invalidArchive
                }

                let service = JourneyImportService(dao: dao)
                let parsedContainer = try service.parseArchive(data)
                let detectedConflicts = try service.detectConflicts(in: parsedContainer)

                await MainActor.run {
                    self.importData = data
                    self.container = parsedContainer
                    self.conflicts = detectedConflicts
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func performImport() {
        guard let data = importData else { return }

        isImporting = true
        errorMessage = nil

        Task {
            do {
                guard let dao = store.dao else {
                    throw JourneyImportService.ImportError.invalidArchive
                }

                let service = JourneyImportService(dao: dao)
                let result = try service.importArchive(
                    data,
                    resolutions: resolutions,
                    defaultResolution: defaultResolution
                )

                await MainActor.run {
                    self.importResult = result
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isImporting = false
                }
            }
        }
    }
}
