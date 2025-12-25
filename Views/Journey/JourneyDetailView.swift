// Views/Journey/JourneyDetailView.swift
import SwiftUI

struct JourneyDetailView: View {
    let node: JourneyNode
    @State private var showEditor = false
    @EnvironmentObject var store: JourneyStore

    // Attachments State
    @State private var attachments: [JourneyAttachment] = []
    @State private var isLoadingAttachments: Bool = false
    @State private var selectedAttachment: JourneyAttachment?
    @State private var showPhotoPicker: Bool = false
    @State private var showDocumentPicker: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Content
                if let content = node.content, !content.isEmpty {
                    contentSection(content)
                } else {
                    ContentUnavailableView {
                        Label("Kein Inhalt", systemImage: "doc.text")
                    }
                }

                // Attachments Section
                if node.nodeType != .folder {
                    Divider()
                    attachmentsSection
                }

                Divider()

                // Meta Info
                metaSection

                // Tags
                if !node.tags.isEmpty {
                    tagsSection
                }

                // Task-spezifisch
                if node.nodeType == .task {
                    taskSection
                }
            }
            .padding()
        }
        .navigationTitle(node.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditor = true
                } label: {
                    Text("journey.detail.edit")
                }
            }

            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    // Attachment hinzufügen
                    Menu {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label(String(localized: "journey.attachments.photo"), systemImage: "photo")
                        }

                        Button {
                            showDocumentPicker = true
                        } label: {
                            Label(String(localized: "journey.attachments.file"), systemImage: "doc")
                        }
                    } label: {
                        Label(String(localized: "journey.attachments.add"), systemImage: "paperclip")
                    }

                    Divider()

                    Button(action: { /* TODO: Export */ }) {
                        Label("Als PDF exportieren", systemImage: "doc.richtext")
                    }
                    Button(action: { /* TODO: Export */ }) {
                        Label("Als Markdown exportieren", systemImage: "doc.plaintext")
                    }

                    Divider()

                    Button(role: .destructive, action: { deleteNode() }) {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                JourneyEditorView(node: node)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            JourneyPhotoPicker(
                isPresented: $showPhotoPicker,
                nodeId: node.id,
                onComplete: { loadAttachments() }
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showDocumentPicker) {
            JourneyDocumentPickerSheet(
                isPresented: $showDocumentPicker,
                nodeId: node.id,
                onComplete: { loadAttachments() }
            )
            .environmentObject(store)
        }
        .sheet(item: $selectedAttachment) { attachment in
            JourneyAttachmentViewer(attachment: attachment)
                .environmentObject(store)
        }
        .task {
            loadAttachments()
        }
    }

    // MARK: - Actions

    private func deleteNode() {
        Task {
            do {
                try await store.deleteNode(node)
            } catch {
                print("❌ Failed to delete node: \(error)")
            }
        }
    }

    private func loadAttachments() {
        isLoadingAttachments = true
        Task {
            do {
                attachments = try await store.getAttachments(for: node.id)
            } catch {
                print("❌ Load attachments failed: \(error)")
            }
            isLoadingAttachments = false
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: node.nodeType.icon)
                .font(.largeTitle)
                .foregroundStyle(sectionColor)
                .frame(width: 60, height: 60)
                .background(sectionColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(node.section.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func contentSection(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("journey.detail.content")
                .font(.headline)

            Text(content)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "journey.attachments"))
                    .font(.headline)

                Spacer()

                if !attachments.isEmpty {
                    Text("\(attachments.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if isLoadingAttachments {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                JourneyAttachmentGallery(
                    attachments: attachments,
                    onDelete: nil,  // Read-only in Detail View
                    onTap: { attachment in
                        selectedAttachment = attachment
                    }
                )
                .environmentObject(store)
            }
        }
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(String(localized: "journey.detail.created"), systemImage: "calendar")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(node.createdAt, style: .date)
            }
            .font(.subheadline)

            HStack {
                Label(String(localized: "journey.detail.modified"), systemImage: "clock")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(node.modifiedAt, style: .relative)
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("journey.detail.tags")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(node.tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = node.status {
                HStack {
                    Label(String(localized: "journey.detail.status"), systemImage: "flag")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(status.title, systemImage: status.icon)
                        .foregroundStyle(statusColor(status))
                }
            }

            if let dueDate = node.dueDate {
                HStack {
                    Label(String(localized: "journey.detail.dueDate"), systemImage: "calendar.badge.clock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(dueDate, style: .date)
                }
            }

            if let progress = node.progress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(String(localized: "journey.detail.progress"), systemImage: "chart.bar")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(progress)%")
                    }
                    ProgressView(value: Double(progress), total: 100)
                        .tint(.green)
                }
            }
        }
        .font(.subheadline)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private var sectionColor: Color {
        switch node.section {
        case .inbox: return .orange
        case .journal: return .purple
        case .wiki: return .blue
        case .projects: return .green
        }
    }

    private func statusColor(_ status: JourneyTaskStatus) -> Color {
        switch status {
        case .open: return .gray
        case .inProgress: return .blue
        case .done: return .green
        case .cancelled: return .red
        }
    }
}

#Preview {
    NavigationStack {
        JourneyDetailView(node: JourneyMockData.wikiNodes.first!.children!.first!.children!.first!)
            .environmentObject(JourneyStore.shared)
    }
}
