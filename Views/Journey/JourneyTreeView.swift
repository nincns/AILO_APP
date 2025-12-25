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

// MARK: - Single Tree Node View

struct JourneyTreeNodeView: View {
    let node: JourneyNode
    let section: JourneySection
    let level: Int

    @Binding var draggedNode: JourneyNode?
    @Binding var dropTargetId: UUID?

    @EnvironmentObject private var store: JourneyStore
    @State private var isExpanded: Bool = true
    @State private var showMoveSheet: Bool = false
    @State private var showEditSheet: Bool = false
    @State private var showDeleteAlert: Bool = false
    @State private var newlyCreatedNode: JourneyNode?
    @State private var showNewNodeEditor: Bool = false

    private var isDropTarget: Bool {
        dropTargetId == node.id && draggedNode?.id != node.id
    }

    private var canAcceptDrop: Bool {
        // Kann Drop akzeptieren wenn:
        // - Nicht auf sich selbst
        // - Nicht auf eigene Kinder (würde Zyklus erzeugen)
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
        .sheet(isPresented: $showMoveSheet) {
            JourneyMoveSheet(node: node)
                .environmentObject(store)
        }
        .sheet(isPresented: $showEditSheet) {
            NavigationStack {
                JourneyEditorView(node: node)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showNewNodeEditor) {
            if let newNode = newlyCreatedNode {
                NavigationStack {
                    JourneyEditorView(node: newNode, isNewlyCreated: true)
                        .environmentObject(store)
                }
            }
        }
        .alert(String(localized: "journey.delete.confirm.title"), isPresented: $showDeleteAlert) {
            Button(String(localized: "common.cancel"), role: .cancel) { }
            Button(String(localized: "common.delete"), role: .destructive) {
                deleteNode()
            }
        } message: {
            Text("journey.delete.confirm.message \(node.title)")
        }
    }

    // MARK: - Node Row mit Drag & Drop

    @ViewBuilder
    private var nodeRowWithDragDrop: some View {
        JourneyNodeRow(node: node)
            // Drag Source
            .draggable(node) {
                // Drag Preview
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
                    showDeleteAlert = true
                } label: {
                    Label(String(localized: "common.delete"), systemImage: "trash")
                }

                Button {
                    showEditSheet = true
                } label: {
                    Label(String(localized: "journey.context.edit"), systemImage: "pencil")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    showMoveSheet = true
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
            showEditSheet = true
        } label: {
            Label(String(localized: "journey.context.edit"), systemImage: "pencil")
        }

        Button {
            showMoveSheet = true
        } label: {
            Label(String(localized: "journey.context.move"), systemImage: "folder")
        }

        if node.nodeType == .folder {
            Divider()

            Button {
                createChildEntry()
            } label: {
                Label(String(localized: "journey.context.newEntry"), systemImage: "doc.badge.plus")
            }

            Button {
                createChildFolder()
            } label: {
                Label(String(localized: "journey.context.newFolder"), systemImage: "folder.badge.plus")
            }
        }

        Divider()

        Button(role: .destructive) {
            showDeleteAlert = true
        } label: {
            Label(String(localized: "journey.context.delete"), systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func handleDrop(_ dropped: JourneyNode) -> Bool {
        guard canAcceptDrop else { return false }

        Task {
            do {
                // Node unter diesen Parent verschieben
                try await store.moveNode(dropped, toParent: node.id, sortOrder: 0)
            } catch {
                print("❌ Drop failed: \(error)")
            }
        }

        return true
    }

    private func deleteNode() {
        Task {
            do {
                try await store.deleteNode(node)
            } catch {
                print("❌ Delete failed: \(error)")
            }
        }
    }

    private func createChildEntry() {
        Task {
            do {
                let newNode = try await store.createNode(
                    section: section,
                    nodeType: .entry,
                    title: String(localized: "journey.new.entry"),
                    parentId: node.id
                )
                // Kleine Verzögerung damit Kontextmenü vollständig schließt
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    newlyCreatedNode = newNode
                    showNewNodeEditor = true
                }
            } catch {
                print("❌ Create child failed: \(error)")
            }
        }
    }

    private func createChildFolder() {
        Task {
            do {
                let newNode = try await store.createNode(
                    section: section,
                    nodeType: .folder,
                    title: String(localized: "journey.new.folder"),
                    parentId: node.id
                )
                // Kleine Verzögerung damit Kontextmenü vollständig schließt
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    newlyCreatedNode = newNode
                    showNewNodeEditor = true
                }
            } catch {
                print("❌ Create child folder failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Prüft ob `child` ein Nachkomme von `parent` ist
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
