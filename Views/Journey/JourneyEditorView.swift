// Views/Journey/JourneyEditorView.swift
import SwiftUI

struct JourneyEditorView: View {
    let node: JourneyNode?
    let isNewlyCreated: Bool
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

    // Original values to detect changes
    @State private var originalTitle: String = ""

    private var isNewNode: Bool { node == nil }

    private var hasUnsavedChanges: Bool {
        title != originalTitle || !content.isEmpty || !tagsText.isEmpty
    }

    init(node: JourneyNode? = nil, isNewlyCreated: Bool = false) {
        self.node = node
        self.isNewlyCreated = isNewlyCreated
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
            }
        }
    }

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
                } else {
                    // Create new node
                    _ = try await store.createNode(
                        section: selectedSection,
                        nodeType: selectedType,
                        title: title,
                        content: content.isEmpty ? nil : content,
                        parentId: nil,
                        tags: parseTags()
                    )
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
