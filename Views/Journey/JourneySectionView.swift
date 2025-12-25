// Views/Journey/JourneySectionView.swift
import SwiftUI

struct JourneySectionView: View {
    let section: JourneySection
    @Binding var searchText: String

    private var nodes: [JourneyNodeMock] {
        JourneyMockData.nodes(for: section)
    }

    private var filteredNodes: [JourneyNodeMock] {
        guard !searchText.isEmpty else { return nodes }
        return filterNodes(nodes, searchText: searchText)
    }

    var body: some View {
        Group {
            if filteredNodes.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "journey.empty"), systemImage: section.icon)
                } description: {
                    Text("journey.action.new")
                }
            } else {
                List {
                    JourneyTreeView(nodes: filteredNodes, section: section)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // Rekursive Filterung
    private func filterNodes(_ nodes: [JourneyNodeMock], searchText: String) -> [JourneyNodeMock] {
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
    }
}
