// Views/Journey/JourneyTreeView.swift
import SwiftUI

struct JourneyTreeView: View {
    let nodes: [JourneyNodeMock]
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
                nodes: JourneyMockData.wiki,
                section: .wiki
            )
        }
        .listStyle(.sidebar)
    }
}
