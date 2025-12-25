// Views/Journey/JourneyDetailView.swift
import SwiftUI

struct JourneyDetailView: View {
    let node: JourneyNodeMock
    @State private var showEditor = false

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
                    Button(action: { /* TODO: Export */ }) {
                        Label("Als PDF exportieren", systemImage: "doc.richtext")
                    }
                    Button(action: { /* TODO: Export */ }) {
                        Label("Als Markdown exportieren", systemImage: "doc.plaintext")
                    }
                    Divider()
                    Button(role: .destructive, action: { /* TODO: Delete */ }) {
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
            }
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

    private func statusColor(_ status: TaskStatus) -> Color {
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
        JourneyDetailView(node: JourneyMockData.wiki.first!.children!.first!.children!.first!)
    }
}
