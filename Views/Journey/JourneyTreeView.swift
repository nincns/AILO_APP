// Views/Journey/JourneyTreeView.swift
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Presentation Types

/// Enum für alle möglichen Sheet-Präsentationen
enum JourneySheetType: Identifiable, Equatable {
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

    static func == (lhs: JourneySheetType, rhs: JourneySheetType) -> Bool {
        lhs.id == rhs.id
    }
}

/// Enum für Alert-Präsentationen
enum JourneyAlertType: Identifiable, Equatable {
    case delete(JourneyNode)

    var id: String {
        switch self {
        case .delete(let node): return "delete-\(node.id)"
        }
    }

    static func == (lhs: JourneyAlertType, rhs: JourneyAlertType) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Presentation State (shared across tree)

@MainActor
class JourneyPresentationState: ObservableObject {
    @Published var activeSheet: JourneySheetType?
    @Published var activeAlert: JourneyAlertType?
    private var isTransitioning: Bool = false

    func presentSheet(_ sheet: JourneySheetType) {
        guard !isTransitioning, activeSheet == nil, activeAlert == nil else {
            print("⚠️ Sheet blocked - presentation in progress")
            return
        }
        isTransitioning = true
        // Längere Verzögerung für Sheets (Kontextmenü braucht ~350ms zum Schließen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.activeSheet = sheet
            self?.isTransitioning = false
        }
    }

    func presentAlert(_ alert: JourneyAlertType) {
        // Alert immer erlauben, aber vorherige dismissieren
        if activeSheet != nil {
            activeSheet = nil
        }

        // Direkt setzen wenn kein Alert aktiv, sonst mit kurzer Verzögerung
        if activeAlert == nil && !isTransitioning {
            activeAlert = alert
        } else {
            isTransitioning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.activeAlert = alert
                self?.isTransitioning = false
            }
        }
    }

    func dismissAll() {
        activeSheet = nil
        activeAlert = nil
        isTransitioning = false
    }
}

// MARK: - Tree View

struct JourneyTreeView: View {
    let nodes: [JourneyNode]
    let section: JourneySection
    let level: Int

    @EnvironmentObject private var store: JourneyStore
    @StateObject private var presentationState = JourneyPresentationState()
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
                dropTargetId: $dropTargetId,
                presentationState: presentationState
            )
        }
        .onMove { indices, destination in
            handleReorder(indices: indices, destination: destination)
        }
        // EINZIGER Sheet-Modifier für den ganzen Tree
        .sheet(item: $presentationState.activeSheet) { sheetType in
            sheetContent(for: sheetType)
        }
        // EINZIGER Alert-Modifier für den ganzen Tree
        .alert(
            String(localized: "journey.delete.confirm.title"),
            isPresented: Binding(
                get: { presentationState.activeAlert != nil },
                set: { newValue in
                    if !newValue {
                        Task { @MainActor in
                            presentationState.activeAlert = nil
                        }
                    }
                }
            ),
            presenting: presentationState.activeAlert
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

    private func handleReorder(indices: IndexSet, destination: Int) {
        guard let sourceIndex = indices.first else { return }
        let node = nodes[sourceIndex]

        Task {
            do {
                try await store.moveNode(node, toParent: node.parentId, sortOrder: destination)
            } catch {
                print("❌ Reorder failed: \(error)")
            }
        }
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
}

// MARK: - Single Tree Node View

struct JourneyTreeNodeView: View {
    let node: JourneyNode
    let section: JourneySection
    let level: Int

    @Binding var draggedNode: JourneyNode?
    @Binding var dropTargetId: UUID?
    @ObservedObject var presentationState: JourneyPresentationState

    @EnvironmentObject private var store: JourneyStore
    @State private var isExpanded: Bool = true

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
                    // Rekursive Kinder teilen denselben presentationState
                    ForEach(children) { child in
                        JourneyTreeNodeView(
                            node: child,
                            section: section,
                            level: level + 1,
                            draggedNode: $draggedNode,
                            dropTargetId: $dropTargetId,
                            presentationState: presentationState
                        )
                    }
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
    }

    // MARK: - Node Row mit Drag & Drop

    @ViewBuilder
    private var nodeRowWithDragDrop: some View {
        JourneyNodeRow(node: node)
            .draggable(node) {
                JourneyNodeRow(node: node)
                    .frame(width: 250)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 4)
            }
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
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .contextMenu {
                contextMenuItems
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    // Direkt löschen ohne Bestätigungsdialog
                    Task {
                        do {
                            try await store.deleteNode(node)
                        } catch {
                            print("❌ Delete failed: \(error)")
                        }
                    }
                } label: {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }

                Button {
                    presentationState.presentSheet(.edit(node))
                } label: {
                    Label(String(localized: "journey.context.edit"), systemImage: "pencil")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    presentationState.presentSheet(.move(node))
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
            presentationState.presentSheet(.edit(node))
        } label: {
            Label(String(localized: "journey.context.edit"), systemImage: "pencil")
        }

        Button {
            presentationState.presentSheet(.move(node))
        } label: {
            Label(String(localized: "journey.context.move"), systemImage: "folder")
        }

        if node.nodeType == .folder {
            Divider()

            Button {
                presentationState.presentSheet(.newNode(parentId: node.id, section: section, nodeType: .entry))
            } label: {
                Label(String(localized: "journey.context.newEntry"), systemImage: "doc.badge.plus")
            }

            Button {
                presentationState.presentSheet(.newNode(parentId: node.id, section: section, nodeType: .folder))
            } label: {
                Label(String(localized: "journey.context.newFolder"), systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button(role: .destructive) {
            presentationState.presentAlert(.delete(node))
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
