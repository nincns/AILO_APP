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

    /// Flache Liste aller Ordner mit Einrückungsebene
    private var flattenedFolders: [(folder: JourneyNode, level: Int)] {
        var result: [(JourneyNode, Int)] = []

        func flatten(_ nodes: [JourneyNode], level: Int) {
            for n in nodes {
                // Nicht den zu verschiebenden Node oder seine Kinder anzeigen
                guard n.id != node.id else { continue }
                guard !isDescendant(of: node, child: n) else { continue }

                // Nur Ordner als Ziel anzeigen
                if n.nodeType == .folder {
                    result.append((n, level))
                }

                // Kinder rekursiv hinzufügen
                if let children = n.children {
                    flatten(children, level: level + 1)
                }
            }
        }

        flatten(store.nodes(for: selectedSection), level: 0)
        return result
    }

    /// Prüft ob child ein Nachkomme von parent ist
    private func isDescendant(of parent: JourneyNode, child: JourneyNode) -> Bool {
        guard let children = parent.children else { return false }
        for c in children {
            if c.id == child.id { return true }
            if isDescendant(of: c, child: child) { return true }
        }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                // Section Picker
                Section(String(localized: "journey.move.section")) {
                    Picker("Section", selection: $selectedSection) {
                        ForEach(JourneySection.allCases) { section in
                            Label(section.title, systemImage: section.icon)
                                .tag(section)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedSection) { _, _ in
                        // Bei Sektionswechsel auf Root zurücksetzen
                        selectedParentId = nil
                    }
                }

                // Zielordner-Auswahl
                Section(String(localized: "journey.move.parent")) {
                    // Root-Option (Stammebene)
                    Button {
                        selectedParentId = nil
                    } label: {
                        HStack {
                            Image(systemName: "house")
                                .foregroundStyle(.secondary)
                            Text(String(localized: "journey.move.root"))
                            Spacer()
                            if selectedParentId == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Alle Ordner (flach mit Einrückung)
                    ForEach(flattenedFolders, id: \.folder.id) { item in
                        Button {
                            selectedParentId = item.folder.id
                        } label: {
                            HStack(spacing: 8) {
                                // Einrückung
                                if item.level > 0 {
                                    Spacer()
                                        .frame(width: CGFloat(item.level) * 20)
                                }

                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.yellow)

                                Text(item.folder.title)
                                    .lineLimit(1)

                                Spacer()

                                if selectedParentId == item.folder.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if flattenedFolders.isEmpty {
                        Text(String(localized: "journey.move.noFolders"))
                            .foregroundStyle(.secondary)
                            .italic()
                    }
                }

                // Fehleranzeige
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
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
                    .disabled(isLoading || !hasChanges)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
    }

    private var hasChanges: Bool {
        selectedSection != node.section || selectedParentId != node.parentId
    }

    private func performMove() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                if selectedSection != node.section {
                    // Section UND Parent ändern
                    var updatedNode = node
                    updatedNode.section = selectedSection
                    updatedNode.parentId = selectedParentId
                    try await store.updateNode(updatedNode)
                } else if selectedParentId != node.parentId {
                    // Nur Parent ändern
                    try await store.moveNode(node, toParent: selectedParentId, sortOrder: 0)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    JourneyMoveSheet(node: JourneyMockData.wikiNodes.first!.children!.first!)
        .environmentObject(JourneyStore.shared)
}
