// Views/Journey/JourneyView.swift
import SwiftUI

struct JourneyView: View {
    @StateObject private var store = JourneyStore.shared
    @State private var selectedSection: JourneySection = .inbox
    @State private var searchText: String = ""
    @State private var nodeToEdit: JourneyNode?
    @State private var isNewlyCreated: Bool = false
    @State private var showEditor = false

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
        }
        .navigationTitle(String(localized: "journey.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: { createFolder() }) {
                        Label(String(localized: "journey.action.newFolder"), systemImage: "folder.badge.plus")
                    }
                    Button(action: { createEntry() }) {
                        Label(String(localized: "journey.action.newEntry"), systemImage: "doc.badge.plus")
                    }
                    if selectedSection == .projects {
                        Button(action: { createTask() }) {
                            Label(String(localized: "journey.action.newTask"), systemImage: "checkmark.circle.badge.plus")
                        }
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
        .sheet(isPresented: $showEditor) {
            if let node = nodeToEdit {
                NavigationStack {
                    JourneyEditorView(node: node, isNewlyCreated: isNewlyCreated)
                        .environmentObject(store)
                }
            }
        }
    }

    // MARK: - Actions

    private func createFolder() {
        Task {
            do {
                let node = try await store.createNode(
                    section: selectedSection,
                    nodeType: .folder,
                    title: String(localized: "journey.new.folder")
                )
                await MainActor.run {
                    nodeToEdit = node
                    isNewlyCreated = true
                    showEditor = true
                }
            } catch {
                print("❌ Failed to create folder: \(error)")
            }
        }
    }

    private func createEntry() {
        Task {
            do {
                let node = try await store.createNode(
                    section: selectedSection,
                    nodeType: .entry,
                    title: String(localized: "journey.new.entry")
                )
                await MainActor.run {
                    nodeToEdit = node
                    isNewlyCreated = true
                    showEditor = true
                }
            } catch {
                print("❌ Failed to create entry: \(error)")
            }
        }
    }

    private func createTask() {
        Task {
            do {
                let node = try await store.createNode(
                    section: selectedSection,
                    nodeType: .task,
                    title: String(localized: "journey.new.task")
                )
                await MainActor.run {
                    nodeToEdit = node
                    isNewlyCreated = true
                    showEditor = true
                }
            } catch {
                print("❌ Failed to create task: \(error)")
            }
        }
    }
}

#Preview {
    NavigationStack {
        JourneyView()
    }
}
