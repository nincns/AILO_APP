// Views/Journey/JourneyView.swift
import SwiftUI

struct JourneyView: View {
    @State private var selectedSection: JourneySection = .inbox
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
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
        }
        .navigationTitle(String(localized: "journey.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "journey.search.placeholder")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: { /* TODO */ }) {
                        Label(String(localized: "journey.action.newFolder"), systemImage: "folder.badge.plus")
                    }
                    Button(action: { /* TODO */ }) {
                        Label(String(localized: "journey.action.newEntry"), systemImage: "doc.badge.plus")
                    }
                    if selectedSection == .projects {
                        Button(action: { /* TODO */ }) {
                            Label(String(localized: "journey.action.newTask"), systemImage: "checkmark.circle.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        JourneyView()
    }
}
