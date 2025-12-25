// Views/Journey/JourneyMoveSheet.swift
import SwiftUI

struct JourneyMoveSheet: View {
    let node: JourneyNode

    @EnvironmentObject private var store: JourneyStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedParentId: UUID?
    @State private var selectedSection: JourneySection
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    init(node: JourneyNode) {
        self.node = node
        _selectedSection = State(initialValue: node.section)
        _selectedParentId = State(initialValue: node.parentId)
    }

    private var availableNodes: [JourneyNode] {
        store.nodes(for: selectedSection)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Section Picker
                Section(String(localized: "journey.move.section")) {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(JourneySection.allCases) { section in
                            Label(section.title, systemImage: section.icon)
                                .tag(section)
                        }
                    }
                    .pickerStyle(.menu)
                }

                // Parent Picker
                Section(String(localized: "journey.move.parent")) {
                    // Root-Option
                    Button {
                        selectedParentId = nil
                    } label: {
                        HStack {
                            Image(systemName: "house")
                            Text("\(String(localized: "journey.move.root")) (\(selectedSection.title))")
                            Spacer()
                            if selectedParentId == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .foregroundColor(.primary)

                    // Folder-Liste (rekursiv)
                    ForEach(availableNodes) { parentNode in
                        if parentNode.id != node.id {
                            ParentPickerRow(
                                node: parentNode,
                                selectedId: $selectedParentId,
                                excludeId: node.id,
                                level: 0
                            )
                        }
                    }
                }

                // Info
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "journey.move.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "journey.move.confirm")) {
                        performMove()
                    }
                    .disabled(isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
    }

    private func performMove() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Wenn Section gewechselt wurde, müssen wir auch Section ändern
                if selectedSection != node.section {
                    var updatedNode = node
                    updatedNode.section = selectedSection
                    updatedNode.parentId = selectedParentId
                    try await store.updateNode(updatedNode)
                } else {
                    try await store.moveNode(node, toParent: selectedParentId, sortOrder: 0)
                }
                dismiss()
            } catch {
                errorMessage = "\(String(localized: "journey.move.error")): \(error.localizedDescription)"
            }
            isLoading = false
        }
    }
}

// MARK: - Rekursive Parent Picker Row

struct ParentPickerRow: View {
    let node: JourneyNode
    @Binding var selectedId: UUID?
    let excludeId: UUID
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Diese Node
            if node.nodeType == .folder {
                Button {
                    selectedId = node.id
                } label: {
                    HStack {
                        // Einrückung
                        if level > 0 {
                            ForEach(0..<level, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: 20)
                            }
                        }

                        Image(systemName: "folder.fill")
                            .foregroundColor(.yellow)

                        Text(node.title)

                        Spacer()

                        if selectedId == node.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .foregroundColor(.primary)
            }

            // Kinder (rekursiv)
            if let children = node.children {
                ForEach(children) { child in
                    if child.id != excludeId {
                        ParentPickerRow(
                            node: child,
                            selectedId: $selectedId,
                            excludeId: excludeId,
                            level: level + 1
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    JourneyMoveSheet(node: JourneyMockData.wikiNodes.first!.children!.first!)
        .environmentObject(JourneyStore.shared)
}
