// Views/Journey/JourneyTreeView.swift
import SwiftUI
import UniformTypeIdentifiers

struct JourneyTreeView: View {
    let nodes: [JourneyNode]
    let section: JourneySection
    let level: Int

    @EnvironmentObject private var store: JourneyStore
    @State private var draggedNode: JourneyNode?
    @State private var dropTargetId: UUID?

    init(nodes: [JourneyNode], section: JourneySection, level: Int = 0) {
        self.nodes = nodes
        self.section = section
        self.level = level
    }

    var body: some View {
        ForEach(nodes) { node in
            JourneyTreeNodeView(
                node: node,
                section: section,
                level: level,
                draggedNode: $draggedNode,
                dropTargetId: $dropTargetId
            )
        }
        .onMove { indices, destination in
            handleReorder(indices: indices, destination: destination)
        }
    }

    private func handleReorder(indices: IndexSet, destination: Int) {
        guard let sourceIndex = indices.first else { return }
        let node = nodes[sourceIndex]

        // Neue sortOrder berechnen
        let newSortOrder = destination

        Task {
            do {
                try await store.moveNode(node, toParent: node.parentId, sortOrder: newSortOrder)
            } catch {
                print("❌ Reorder failed: \(error)")
            }
        }
    }
}

// MARK: - Presentation Types

/// Enum für alle möglichen Sheet-Präsentationen
enum JourneySheetType: Identifiable {
    case edit(JourneyNode)
    case move(JourneyNode)
    case newNode(parentId: UUID, section: JourneySection, nodeType: JourneyNodeType)

    var id: String {
        switch self {
        case .edit(let node): return "edit-\(node.id)"
        case .move(let node): return "move-\(node.id)"
        case .newNode(let parentId, _, let nodeType): return "new-\(parentId)-\(nodeType)"
        }
    }
}

/// Enum für Alert-Präsentationen
enum JourneyAlertType: Identifiable {
    case delete(JourneyNode)

    var id: String {
        switch self {
        case .delete(let node): return "delete-\(node.id)"
        }
    }
}

// MARK: - Single Tree Node View

struct JourneyTreeNodeView: View {
    let node: JourneyNode
    let section: JourneySection
    let level: Int

    @Binding var draggedNode: JourneyNode?
    @Binding var dropTargetId: UUID?

    @EnvironmentObject private var store: JourneyStore
    @State private var isExpanded: Bool = true

    // Unified presentation state - nur EINE Präsentation gleichzeitig möglich
    @State private var activeSheet: JourneySheetType?
    @State private var activeAlert: JourneyAlertType?
    @State private var isPresentationInProgress: Bool = false

    private var isDropTarget: Bool {
        dropTargetId == node.id && draggedNode?.id != node.id
    }

    private var canAcceptDrop: Bool {
        guard let dragged = draggedNode else { return false }
        if dragged.id == node.id { return false }
        if isDescendant(of: dragged, node: node) { return false }
        return true
    }

    var body: some View {
        Group {
            if let children = node.children, !children.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    JourneyTreeView(nodes: children, section: section, level: level + 1)
                        .environmentObject(store)
                } label: {
                    nodeRowWithDragDrop
                }
            } else {
                NavigationLink {
                    JourneyDetailView(node: node)
                        .environmentObject(store)
                } label: {
                    nodeRowWithDragDrop
                }
            }
        }
        // Unified Sheet - nur ein Sheet kann aktiv sein
        .sheet(item: $activeSheet, onDismiss: {
            isPresentationInProgress = false
        }) { sheetType in
            sheetContent(for: sheetType)
        }
        // Alert für Löschbestätigung
        .alert(
            String(localized: "journey.delete.confirm.title"),
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { if !$0 { activeAlert = nil; isPresentationInProgress = false } }
            ),
            presenting: activeAlert
        ) { alertType in
            Button(String(localized: "common.cancel"), role: .cancel) { }
            Button(String(localized: "common.delete"), role: .destructive) {
                if case .delete(let nodeToDelete) = alertType {
                    deleteNode(nodeToDelete)
                }
            }
        } message: { alertType in
            if case .delete(let nodeToDelete) = alertType {
                Text("journey.delete.confirm.message \(nodeToDelete.title)")
            }
        }
    }

    // MARK: - Sheet Content

    @ViewBuilder
    private func sheetContent(for type: JourneySheetType) -> some View {
        switch type {
        case .edit(let nodeToEdit):
            NavigationStack {
                JourneyEditorView(node: nodeToEdit)
                    .environmentObject(store)
            }

        case .move(let nodeToMove):
            JourneyMoveSheet(node: nodeToMove)
                .environmentObject(store)

        case .newNode(let parentId, let section, let nodeType):
            NavigationStack {
                JourneyEditorView(
                    parentId: parentId,
                    preselectedSection: section,
                    preselectedType: nodeType
                )
                .environmentObject(store)
            }
        }
    }

    // MARK: - Safe Presentation

    /// Zeigt ein Sheet nur wenn keine andere Präsentation aktiv ist
    private func presentSheet(_ sheet: JourneySheetType) {
        guard !isPresentationInProgress else {
            print("⚠️ Presentation blocked - another presentation in progress")
            return
        }
        isPresentationInProgress = true
        activeSheet = sheet
    }

    /// Zeigt ein Alert nur wenn keine andere Präsentation aktiv ist
    private func presentAlert(_ alert: JourneyAlertType) {
        guard !isPresentationInProgress else {
            print("⚠️ Alert blocked - another presentation in progress")
            return
        }
        isPresentationInProgress = true
        activeAlert = alert
    }

    // MARK: - Node Row mit Drag & Drop

    @ViewBuilder
    private var nodeRowWithDragDrop: some View {
        JourneyNodeRow(node: node)
            // Drag Source
            .draggable(node) {
                JourneyNodeRow(node: node)
                    .frame(width: 250)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
            }
            // Drop Target
            .dropDestination(for: JourneyNode.self) { droppedNodes, _ in
                guard let dropped = droppedNodes.first else { return false }
                return handleDrop(dropped)
            } isTargeted: { isTargeted in
                if isTargeted && canAcceptDrop {
                    dropTargetId = node.id
                } else if dropTargetId == node.id {
                    dropTargetId = nil
                }
            }
            // Visual Feedback für Drop Target
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            // Context Menu
            .contextMenu {
                contextMenuItems
            }
            // Swipe Actions
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    presentAlert(.delete(node))
                } label: {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }

                Button {
                    presentSheet(.edit(node))
                } label: {
                    Label(String(localized: "journey.context.edit"), systemImage: "pencil")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    presentSheet(.move(node))
                } label: {
                    Label(String(localized: "journey.context.move"), systemImage: "folder")
                }
                .tint(.orange)
            }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            presentSheet(.edit(node))
        } label: {
            Label(String(localized: "journey.context.edit"), systemImage: "pencil")
        }

        Button {
            presentSheet(.move(node))
        } label: {
            Label(String(localized: "journey.context.move"), systemImage: "folder")
        }

        if node.nodeType == .folder {
            Divider()

            Button {
                presentSheet(.newNode(parentId: node.id, section: section, nodeType: .entry))
            } label: {
                Label(String(localized: "journey.context.newEntry"), systemImage: "doc.badge.plus")
            }

            Button {
                presentSheet(.newNode(parentId: node.id, section: section, nodeType: .folder))
            } label: {
                Label(String(localized: "journey.context.newFolder"), systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button(role: .destructive) {
            presentAlert(.delete(node))
        } label: {
            Label(String(localized: "journey.context.delete"), systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func handleDrop(_ dropped: JourneyNode) -> Bool {
        guard canAcceptDrop else { return false }

        Task {
            do {
                try await store.moveNode(dropped, toParent: node.id, sortOrder: 0)
            } catch {
                print("❌ Drop failed: \(error)")
            }
        }

        return true
    }

    private func deleteNode(_ nodeToDelete: JourneyNode) {
        Task {
            do {
                try await store.deleteNode(nodeToDelete)
            } catch {
                print("❌ Delete failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func isDescendant(of parent: JourneyNode, node child: JourneyNode) -> Bool {
        guard let children = parent.children else { return false }
        for c in children {
            if c.id == child.id { return true }
            if isDescendant(of: c, node: child) { return true }
        }
        return false
    }
}

#Preview {
    NavigationStack {
        List {
            JourneyTreeView(
                nodes: JourneyMockData.wikiNodes,
                section: .wiki
            )
        }
        .listStyle(.sidebar)
        .environmentObject(JourneyStore.shared)
    }
}
