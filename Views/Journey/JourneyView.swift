// Views/Journey/JourneyView.swift
import SwiftUI

struct JourneyView: View {
    @StateObject private var store = JourneyStore.shared
    @StateObject private var presentationState = JourneyPresentationState()
    @State private var selectedSection: JourneySection = .inbox
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search Field (fixed)
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "journey.search.placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.top, 8)

            // Section Picker
            Picker("Section", selection: $selectedSection) {
                ForEach(JourneySection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            // Content
            JourneySectionView(
                section: selectedSection,
                searchText: $searchText
            )
            .environmentObject(store)
            .environmentObject(presentationState)
        }
        .navigationTitle(String(localized: "journey.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: { createEntry() }) {
                        Label(String(localized: "journey.action.newEntry"), systemImage: "doc.badge.plus")
                    }
                    Button(action: { createTask() }) {
                        Label(String(localized: "journey.action.newTask"), systemImage: "checkmark.circle.badge.plus")
                    }
                    Divider()
                    Button(action: { createFolder() }) {
                        Label(String(localized: "journey.action.newFolder"), systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Menu {
                        Button(action: { exportSection() }) {
                            Label(String(localized: "journey.export.currentSection"), systemImage: "square.and.arrow.up")
                        }
                        Button(action: { exportAll() }) {
                            Label(String(localized: "journey.export.all"), systemImage: "square.and.arrow.up.on.square")
                        }
                    } label: {
                        Label(String(localized: "journey.action.export"), systemImage: "square.and.arrow.up")
                    }
                    Button(action: { importFile() }) {
                        Label(String(localized: "journey.action.import"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if store.isLoading {
                ProgressView()
            }
        }
        // EINZIGER Sheet-Modifier für die gesamte Journey-Hierarchie
        .sheet(item: $presentationState.activeSheet, onDismiss: {
            presentationState.unlock()
        }) { sheetType in
            sheetContent(for: sheetType)
        }
        // EINZIGER Alert-Modifier für die gesamte Journey-Hierarchie
        .alert(
            String(localized: "journey.delete.confirm.title"),
            isPresented: Binding(
                get: { presentationState.activeAlert != nil },
                set: { newValue in
                    if !newValue {
                        Task { @MainActor in
                            presentationState.unlock()
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

        case .exportNodes(let nodes):
            JourneyExportSheet(nodes: nodes)
                .environmentObject(store)

        case .exportSection(let section):
            JourneyExportSheet(section: section)
                .environmentObject(store)

        case .exportAll:
            JourneyExportSheet()
                .environmentObject(store)

        case .importFile(let url):
            JourneyImportSheet(url: url)
                .environmentObject(store)
        }
    }

    // MARK: - Actions

    private func createFolder() {
        presentationState.presentSheet(.newNode(
            parentId: nil,
            section: selectedSection,
            nodeType: .folder
        ))
    }

    private func createEntry() {
        presentationState.presentSheet(.newNode(
            parentId: nil,
            section: selectedSection,
            nodeType: .entry
        ))
    }

    private func createTask() {
        presentationState.presentSheet(.newNode(
            parentId: nil,
            section: selectedSection,
            nodeType: .task
        ))
    }

    private func deleteNode(_ node: JourneyNode) {
        Task {
            do {
                try await store.deleteNode(node)
            } catch {
                print("❌ Delete failed: \(error)")
            }
        }
    }

    private func exportSection() {
        presentationState.presentSheet(.exportSection(selectedSection))
    }

    private func exportAll() {
        presentationState.presentSheet(.exportAll)
    }

    private func importFile() {
        presentationState.presentSheet(.importFile(nil))
    }
}

#Preview {
    NavigationStack {
        JourneyView()
    }
}
