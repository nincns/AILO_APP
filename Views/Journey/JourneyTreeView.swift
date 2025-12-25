// Views/Journey/JourneyTreeView.swift
import SwiftUI

struct JourneyTreeView: View {
    let nodes: [JourneyNode]
    let section: JourneySection
    @EnvironmentObject var store: JourneyStore

    var body: some View {
        ForEach(nodes) { node in
            if let children = node.children, !children.isEmpty {
                DisclosureGroup {
                    JourneyTreeView(nodes: children, section: section)
                        .environmentObject(store)
                } label: {
                    JourneyNodeRow(node: node)
                }
            } else {
                NavigationLink {
                    JourneyDetailView(node: node)
                        .environmentObject(store)
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
            .environmentObject(JourneyStore.shared)
        }
        .listStyle(.sidebar)
    }
}
