// Views/Journey/JourneyEditorView.swift
import SwiftUI
import PhotosUI

struct JourneyEditorView: View {
    let node: JourneyNode?
    let isNewlyCreated: Bool
    let parentId: UUID?
    let preselectedSection: JourneySection?
    let preselectedType: JourneyNodeType?

    @EnvironmentObject var store: JourneyStore

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var selectedSection: JourneySection = .inbox
    @State private var selectedType: JourneyNodeType = .entry
    @State private var tagsText: String = ""

    // Task-spezifisch
    @State private var status: JourneyTaskStatus = .open
    @State private var dueDate: Date = Date()
    @State private var hasDueDate: Bool = false
    @State private var progress: Double = 0

    // Attachments
    @State private var attachments: [JourneyAttachment] = []
    @State private var pendingAttachments: [(attachment: JourneyAttachment, data: Data)] = []
    @State private var attachmentsToDelete: Set<UUID> = []
    @State private var showPhotoPicker: Bool = false
    @State private var showDocumentPicker: Bool = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isLoadingAttachments: Bool = false
    @State private var selectedAttachment: JourneyAttachment?

    // Contacts
    @State private var contacts: [JourneyContactRef] = []
    @State private var pendingContacts: [JourneyContactRef] = []
    @State private var contactsToDelete: [JourneyContactRef] = []
    @State private var showContactPicker: Bool = false

    // Calendar
    @State private var syncToCalendar: Bool = false

    // Original values to detect changes
    @State private var originalTitle: String = ""

    private var isNewNode: Bool { node == nil }

    private var hasUnsavedChanges: Bool {
        title != originalTitle || !content.isEmpty || !tagsText.isEmpty || !pendingAttachments.isEmpty
    }

    /// Alle sichtbaren Attachments (bestehende + pending, ohne gelöschte)
    private var allAttachments: [JourneyAttachment] {
        let existing = attachments.filter { !attachmentsToDelete.contains($0.id) }
        let pending = pendingAttachments.map { $0.attachment }
        return existing + pending
    }

    init(
        node: JourneyNode? = nil,
        isNewlyCreated: Bool = false,
        parentId: UUID? = nil,
        preselectedSection: JourneySection? = nil,
        preselectedType: JourneyNodeType? = nil
    ) {
        self.node = node
        self.isNewlyCreated = isNewlyCreated
        self.parentId = parentId
        self.preselectedSection = preselectedSection
        self.preselectedType = preselectedType
    }

    var body: some View {
        Form {
            // Basis-Infos
            Section {
                TextField(String(localized: "journey.detail.title"), text: $title)

                if isNewNode {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(JourneySection.allCases) { section in
                            Label(section.title, systemImage: section.icon)
                                .tag(section)
                        }
                    }

                    Picker("Typ", selection: $selectedType) {
                        Label(String(localized: "journey.node.folder"), systemImage: "folder")
                            .tag(JourneyNodeType.folder)
                        Label(String(localized: "journey.node.entry"), systemImage: "doc.text")
                            .tag(JourneyNodeType.entry)
                        if selectedSection == .projects {
                            Label(String(localized: "journey.node.task"), systemImage: "checkmark.circle")
                                .tag(JourneyNodeType.task)
                        }
                    }
                }
            }

            // Inhalt
            if selectedType != .folder {
                Section(String(localized: "journey.detail.content")) {
                    TextEditor(text: $content)
                        .frame(minHeight: 150)
                }

                // Attachments Section
                attachmentsSection
            }

            // Tags
            Section(String(localized: "journey.detail.tags")) {
                TextField("Tag1, Tag2, Kategorie:Wert", text: $tagsText)
                    .textInputAutocapitalization(.never)

                if !tagsText.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(parseTags(), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.15))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Task-spezifisch
            if selectedType == .task || node?.nodeType == .task {
                Section("Aufgabe") {
                    Picker(String(localized: "journey.detail.status"), selection: $status) {
                        ForEach(JourneyTaskStatus.allCases, id: \.self) { s in
                            Label(s.title, systemImage: s.icon)
                                .tag(s)
                        }
                    }

                    Toggle("Fälligkeitsdatum", isOn: $hasDueDate)

                    if hasDueDate {
                        DatePicker(
                            String(localized: "journey.detail.dueDate"),
                            selection: $dueDate,
                            displayedComponents: [.date]
                        )
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text(String(localized: "journey.detail.progress"))
                            Spacer()
                            Text("\(Int(progress))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $progress, in: 0...100, step: 5)
                    }
                }

                // Kalender-Sync Section
                if hasDueDate {
                    Section(String(localized: "journey.calendar")) {
                        Toggle(String(localized: "journey.calendar.sync"), isOn: $syncToCalendar)

                        if syncToCalendar {
                            Text(String(localized: "journey.calendar.willCreate"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Kontakte Section
            if selectedType != .folder {
                contactsSection
            }
        }
        .navigationTitle(isNewNode ? "Neu" : "Bearbeiten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") {
                    cancelEditing()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") {
                    saveNode()
                }
                .disabled(title.isEmpty)
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            JourneyDocumentPickerForEditor(
                isPresented: $showDocumentPicker,
                onSelect: { items in
                    addPendingAttachments(items)
                }
            )
        }
        .sheet(item: $selectedAttachment) { attachment in
            JourneyAttachmentViewer(attachment: attachment)
                .environmentObject(store)
        }
        .sheet(isPresented: $showContactPicker) {
            JourneyContactPickerSheet(
                isPresented: $showContactPicker,
                nodeId: node?.id ?? UUID(),
                onSelect: { contactRef in
                    pendingContacts.append(contactRef)
                }
            )
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            if !newItems.isEmpty {
                processPhotoItems(newItems)
                selectedPhotoItems = []
            }
        }
        .onAppear {
            if let node = node {
                title = node.title
                originalTitle = node.title
                content = node.content ?? ""
                selectedSection = node.section
                selectedType = node.nodeType
                tagsText = node.tags.joined(separator: ", ")
                if let s = node.status { status = s }
                if let d = node.dueDate {
                    dueDate = d
                    hasDueDate = true
                }
                if let p = node.progress { progress = Double(p) }

                // Load attachments
                loadAttachments()

                // Load contacts
                loadContacts()

                // Kalender-Sync Status
                syncToCalendar = node.calendarEventId != nil && !node.calendarEventId!.isEmpty
            } else {
                // Für neue Nodes: preselected values setzen
                if let section = preselectedSection {
                    selectedSection = section
                }
                if let nodeType = preselectedType {
                    selectedType = nodeType
                }
            }
        }
    }

    // MARK: - Contacts Section

    /// Alle sichtbaren Kontakte (bestehende + pending, ohne gelöschte)
    private var allContacts: [JourneyContactRef] {
        let existing = contacts.filter { c in
            !contactsToDelete.contains(where: { $0.id == c.id })
        }
        return existing + pendingContacts
    }

    private var contactsSection: some View {
        Section(String(localized: "journey.contacts")) {
            if allContacts.isEmpty {
                Text(String(localized: "journey.contacts.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(allContacts) { contact in
                    JourneyContactRow(
                        contact: contact,
                        onDelete: {
                            removeContact(contact)
                        }
                    )
                }
            }

            Button {
                showContactPicker = true
            } label: {
                Label(String(localized: "journey.contacts.add"), systemImage: "person.badge.plus")
            }
        }
    }

    private func loadContacts() {
        guard let node = node else { return }
        Task {
            contacts = (try? await store.getContacts(for: node.id)) ?? []
        }
    }

    private func removeContact(_ contact: JourneyContactRef) {
        if let pendingIndex = pendingContacts.firstIndex(where: { $0.id == contact.id }) {
            pendingContacts.remove(at: pendingIndex)
        } else {
            contactsToDelete.append(contact)
        }
    }

    // MARK: - Attachments Section

    private var attachmentsSection: some View {
        Section(String(localized: "journey.attachments")) {
            if isLoadingAttachments {
                ProgressView()
            } else if allAttachments.isEmpty {
                Text(String(localized: "journey.attachments.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(allAttachments) { attachment in
                    Button {
                        // Nur bestehende Attachments können geöffnet werden (nicht pending)
                        if !pendingAttachments.contains(where: { $0.attachment.id == attachment.id }) {
                            selectedAttachment = attachment
                        }
                    } label: {
                        JourneyAttachmentRow(attachment: attachment)
                            .environmentObject(store)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { indices in
                    deleteAttachments(at: indices)
                }
            }

            // Add Buttons
            HStack(spacing: 16) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .any(of: [.images, .videos])
                ) {
                    Label(String(localized: "journey.attachments.photo"), systemImage: "photo")
                }
                .buttonStyle(.bordered)

                Button {
                    showDocumentPicker = true
                } label: {
                    Label(String(localized: "journey.attachments.file"), systemImage: "doc")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attachment Helpers

    private func loadAttachments() {
        guard let node = node else { return }
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

    private func processPhotoItems(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        continue
                    }

                    let filename = generateFilename(for: item)
                    let attachment = JourneyAttachmentService.createAttachment(
                        nodeId: node?.id ?? UUID(),
                        filename: filename,
                        data: data
                    )

                    await MainActor.run {
                        pendingAttachments.append((attachment, data))
                    }
                } catch {
                    print("❌ Photo processing failed: \(error)")
                }
            }
        }
    }

    private func generateFilename(for item: PhotosPickerItem) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let ext: String
        if let type = item.supportedContentTypes.first {
            if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
                ext = "jpg"
            } else if type.conforms(to: .png) {
                ext = "png"
            } else if type.conforms(to: .gif) {
                ext = "gif"
            } else if type.conforms(to: .movie) || type.conforms(to: .quickTimeMovie) {
                ext = "mov"
            } else if type.conforms(to: .mpeg4Movie) {
                ext = "mp4"
            } else {
                ext = type.preferredFilenameExtension ?? "bin"
            }
        } else {
            ext = "jpg"
        }

        return "photo_\(timestamp).\(ext)"
    }

    private func addPendingAttachments(_ items: [(filename: String, data: Data)]) {
        for item in items {
            let attachment = JourneyAttachmentService.createAttachment(
                nodeId: node?.id ?? UUID(),
                filename: item.filename,
                data: item.data
            )
            pendingAttachments.append((attachment, item.data))
        }
    }

    private func deleteAttachments(at indices: IndexSet) {
        for index in indices {
            let attachment = allAttachments[index]

            // Check if pending or existing
            if let pendingIndex = pendingAttachments.firstIndex(where: { $0.attachment.id == attachment.id }) {
                pendingAttachments.remove(at: pendingIndex)
            } else {
                attachmentsToDelete.insert(attachment.id)
            }
        }
    }

    // MARK: - Actions

    private func cancelEditing() {
        // Wenn neu erstellt und keine Änderungen: Node löschen
        if isNewlyCreated, let node = node, !hasUnsavedChanges {
            Task {
                do {
                    try await store.deleteNode(node)
                    print("🗑️ Newly created node deleted (no changes)")
                } catch {
                    print("❌ Failed to delete node: \(error)")
                }
            }
        }
        dismiss()
    }

    private func saveNode() {
        Task {
            do {
                let nodeId: UUID

                if let existingNode = node {
                    // Update existing node
                    var updated = existingNode
                    updated.title = title
                    updated.content = content.isEmpty ? nil : content
                    updated.tags = parseTags()

                    if updated.nodeType == .task {
                        updated.status = status
                        updated.dueDate = hasDueDate ? dueDate : nil
                        updated.progress = Int(progress)
                    }

                    try await store.updateNode(updated)
                    nodeId = existingNode.id
                } else {
                    // Create new node
                    let newNode = try await store.createNode(
                        section: selectedSection,
                        nodeType: selectedType,
                        title: title,
                        content: content.isEmpty ? nil : content,
                        parentId: parentId,
                        tags: parseTags()
                    )
                    nodeId = newNode.id
                }

                // Delete marked attachments
                for attachmentId in attachmentsToDelete {
                    if let attachment = attachments.first(where: { $0.id == attachmentId }) {
                        try? await store.deleteAttachment(attachment)
                    }
                }

                // Save pending attachments
                for pending in pendingAttachments {
                    var attachment = pending.attachment
                    attachment.nodeId = nodeId
                    try? await store.addAttachment(attachment, withData: pending.data)
                }

                // Delete marked contacts
                for contact in contactsToDelete {
                    try? await store.deleteContact(contact)
                }

                // Save pending contacts
                for var contact in pendingContacts {
                    contact.nodeId = nodeId
                    try? await store.addContact(contact)
                }

                // Kalender-Sync
                if syncToCalendar && (selectedType == .task || node?.nodeType == .task) && hasDueDate {
                    // Erstelle/aktualisiere Kalender-Event
                    var nodeForCalendar = node ?? JourneyNode(section: selectedSection, nodeType: selectedType, title: title)
                    nodeForCalendar.title = title
                    nodeForCalendar.dueDate = dueDate
                    nodeForCalendar.status = status

                    if let eventId = try? JourneyCalendarService.shared.syncTask(nodeForCalendar) {
                        var updated = nodeForCalendar
                        updated.id = nodeId
                        updated.calendarEventId = eventId
                        try? await store.updateNode(updated)
                    }
                }

                dismiss()
            } catch {
                print("❌ Failed to save node: \(error)")
            }
        }
    }

    private func parseTags() -> [String] {
        tagsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Document Picker for Editor

struct JourneyDocumentPickerForEditor: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelect: ([(filename: String, data: Data)]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf, .plainText, .rtf, .image, .movie, .audio, .archive, .data
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: JourneyDocumentPickerForEditor

        init(_ parent: JourneyDocumentPickerForEditor) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var items: [(filename: String, data: Data)] = []

            for url in urls {
                // Mit asCopy: true ist die Datei bereits lokal kopiert
                let needsSecurityScope = url.startAccessingSecurityScopedResource()
                defer {
                    if needsSecurityScope {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                if let data = try? Data(contentsOf: url) {
                    items.append((url.lastPathComponent, data))
                }
            }

            parent.onSelect(items)
            parent.isPresented = false
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

#Preview("Neu") {
    NavigationStack {
        JourneyEditorView()
            .environmentObject(JourneyStore.shared)
    }
}

#Preview("Bearbeiten") {
    NavigationStack {
        JourneyEditorView(node: JourneyMockData.projectNodes.first!.children!.first!)
            .environmentObject(JourneyStore.shared)
    }
}
