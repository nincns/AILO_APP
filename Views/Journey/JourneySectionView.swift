// Views/Journey/JourneySectionView.swift
import SwiftUI

struct JourneySectionView: View {
    let section: JourneySection
    @Binding var searchText: String
    @EnvironmentObject var store: JourneyStore
    @EnvironmentObject var presentationState: JourneyPresentationState
    @State private var editMode: EditMode = .inactive

    private var nodes: [JourneyNode] {
        store.nodes(for: section)
    }

    private var filteredNodes: [JourneyNode] {
        guard !searchText.isEmpty else { return nodes }
        return filterNodes(nodes, searchText: searchText)
    }

    var body: some View {
        Group {
            if filteredNodes.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label(String(localized: "journey.empty"), systemImage: section.icon)
                } description: {
                    Text("journey.action.new")
                }
            } else {
                List {
                    JourneyTreeView(nodes: filteredNodes, section: section)
                        .environmentObject(store)
                }
                .listStyle(.sidebar)
                .environment(\.editMode, $editMode)
                .refreshable {
                    await store.refreshSection(section)
                }
            }
        }
        .onAppear {
            Task {
                await store.refreshSection(section)
            }
        }
    }

    // Rekursive Filterung
    private func filterNodes(_ nodes: [JourneyNode], searchText: String) -> [JourneyNode] {
        nodes.compactMap { node in
            let matchesTitle = node.title.localizedCaseInsensitiveContains(searchText)
            let matchesTags = node.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            let matchesContent = node.content?.localizedCaseInsensitiveContains(searchText) ?? false

            if let children = node.children {
                let filteredChildren = filterNodes(children, searchText: searchText)
                if matchesTitle || matchesTags || matchesContent || !filteredChildren.isEmpty {
                    var copy = node
                    copy.children = filteredChildren.isEmpty ? nil : filteredChildren
                    return copy
                }
            } else if matchesTitle || matchesTags || matchesContent {
                return node
            }
            return nil
        }
    }
}

#Preview {
    NavigationStack {
        JourneySectionView(section: .wiki, searchText: .constant(""))
            .environmentObject(JourneyStore.shared)
            .environmentObject(JourneyPresentationState())
    }
}
