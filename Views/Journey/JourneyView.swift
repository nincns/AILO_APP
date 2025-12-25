// Views/Journey/JourneyView.swift
import SwiftUI

struct JourneyView: View {
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
        }
        .navigationTitle(String(localized: "journey.title"))
        .navigationBarTitleDisplayMode(.inline)
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
