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

    // Contacts State
    @State private var contacts: [JourneyContactRef] = []
    @State private var isLoadingContacts: Bool = false
    @State private var showContactPicker: Bool = false

    // Calendar State
    @State private var showCalendarSheet: Bool = false
    @State private var calendarEventTitle: String?

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

                // Contacts Section
                if node.nodeType != .folder {
                    Divider()
                    contactsSection
                }

                // Calendar Section (nur für Tasks)
                if node.nodeType == .task {
                    Divider()
                    calendarSection
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

                    // Kontakt hinzufügen
                    Button {
                        showContactPicker = true
                    } label: {
                        Label(String(localized: "journey.contacts.add"), systemImage: "person.badge.plus")
                    }

                    // Kalender (nur für Tasks mit Deadline)
                    if node.nodeType == .task && node.dueDate != nil && (node.calendarEventId == nil || node.calendarEventId?.isEmpty == true) {
                        Button {
                            showCalendarSheet = true
                        } label: {
                            Label(String(localized: "journey.calendar.add"), systemImage: "calendar.badge.plus")
                        }
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
        .sheet(isPresented: $showContactPicker) {
            JourneyContactPickerSheet(
                isPresented: $showContactPicker,
                nodeId: node.id,
                onSelect: { contactRef in
                    addContact(contactRef)
                }
            )
        }
        .sheet(isPresented: $showCalendarSheet) {
            JourneyCalendarSheet(node: node) { eventId in
                updateCalendarEventId(eventId)
            }
            .environmentObject(store)
        }
        .task {
            loadAttachments()
            loadContacts()
            loadCalendarEvent()
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

    private func loadContacts() {
        isLoadingContacts = true
        Task {
            do {
                contacts = try await store.getContacts(for: node.id)
            } catch {
                print("❌ Load contacts failed: \(error)")
            }
            isLoadingContacts = false
        }
    }

    private func loadCalendarEvent() {
        guard let eventId = node.calendarEventId, !eventId.isEmpty else { return }
        if let event = JourneyCalendarService.shared.fetchEvent(identifier: eventId) {
            calendarEventTitle = event.title
        }
    }

    private func addContact(_ contactRef: JourneyContactRef) {
        Task {
            do {
                try await store.addContact(contactRef)
                loadContacts()
            } catch {
                print("❌ Add contact failed: \(error)")
            }
        }
    }

    private func updateCalendarEventId(_ eventId: String) {
        Task {
            var updated = node
            updated.calendarEventId = eventId
            try? await store.updateNode(updated)
            calendarEventTitle = node.title
        }
    }

    private func openCalendarEvent(_ eventId: String) {
        // Deep-Link in Kalender-App
        if let url = URL(string: "calshow://") {
            UIApplication.shared.open(url)
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

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "journey.contacts"))
                    .font(.headline)

                Spacer()

                if !contacts.isEmpty {
                    Text("\(contacts.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showContactPicker = true
                } label: {
                    Image(systemName: "plus.circle")
                }
            }

            if isLoadingContacts {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if contacts.isEmpty {
                Text(String(localized: "journey.contacts.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(contacts) { contact in
                        JourneyContactRow(contact: contact, onDelete: nil)
                    }
                }
            }
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "journey.calendar"))
                .font(.headline)

            if let eventId = node.calendarEventId, !eventId.isEmpty {
                // Event existiert
                HStack {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundStyle(.green)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "journey.calendar.synced"))
                            .font(.body)
                        if let title = calendarEventTitle {
                            Text(title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(String(localized: "journey.calendar.open")) {
                        openCalendarEvent(eventId)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if node.dueDate != nil {
                // Deadline vorhanden, aber kein Event
                Button {
                    showCalendarSheet = true
                } label: {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                        Text(String(localized: "journey.calendar.add"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Text(String(localized: "journey.calendar.noDeadline"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
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
