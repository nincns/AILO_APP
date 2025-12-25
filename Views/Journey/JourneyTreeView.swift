// Views/Journey/JourneyTreeView.swift
import SwiftUI

struct JourneyTreeView: View {
    let nodes: [JourneyNode]
    let section: JourneySection

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup {
                    JourneyTreeView(nodes: children, section: section)
                } label: {
                    JourneyNodeRow(node: node)
                }
            } else {
                NavigationLink {
                    JourneyDetailView(node: node)
                } label: {
                    JourneyNodeRow(node: node)
                }
            }
        }
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
    }
}
