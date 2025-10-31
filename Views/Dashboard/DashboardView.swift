//Features/Dashboard/DashboardView.swift
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: DataStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var navigateToWrite = false
    @State private var navigateToSpeak = false
    @State private var navigateToLogs = false

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 16
            let isLandscape = proxy.size.width > proxy.size.height
            // Center content using a maxWidth cap to avoid zero-width during rotation glitches

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Banner – dauerhaft mittig zentriert
                    HStack {
                        Spacer(minLength: 0)
                        Image(colorScheme == .dark ? "AppBannerDark" : "AppBannerLight")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .cornerRadius(16)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                    // Upcoming reminders
                    let upcoming: [LogEntry] = Array(
                        store.entries
                            .filter { entry in
                                if let d = entry.reminderDate { return d >= Date() }
                                return false
                            }
                            .sorted { (a, b) in
                                (a.reminderDate ?? .distantFuture) < (b.reminderDate ?? .distantFuture)
                            }
                            .prefix(6)
                    )

                    if !upcoming.isEmpty {
                        Text("dashboard.section.upcoming")
                            .font(.headline)

                        let columns = [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]
                        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                            ForEach(upcoming) { entry in
                                let when = entry.reminderDate ?? Date()
                                NavigationLink {
                                    TextLogDetailView(entry: entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(entry.title ?? (entry.audioFileName != nil ? String(localized: "dashboard.item.type.audio") : String(localized: "dashboard.item.type.text")))
                                                .font(.subheadline).bold()
                                            Spacer()
                                            Text(when.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Text(previewText(for: entry))
                                            .lineLimit(2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                }
                            }
                        }
                    }

                    Text("dashboard.section.recent")
                        .font(.headline)

                    if !store.entries.isEmpty {
                        let recent = Array(store.entries.sorted(by: { $0.date > $1.date }).prefix(6))
                        let columns = [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)]
                        LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                            ForEach(recent) { entry in
                                NavigationLink {
                                    TextLogDetailView(entry: entry)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.title ?? (entry.audioFileName != nil ? String(localized: "dashboard.item.type.audio") : String(localized: "dashboard.item.type.text")))
                                            .font(.subheadline).bold()
                                        Text(previewText(for: entry))
                                            .lineLimit(2)
                                            .foregroundColor(.secondary)
                                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                }
                            }
                        }
                    }
                }
                // Center the entire content block; avoid fixed width to prevent 0-width during rotation
                .frame(maxWidth: 800, alignment: .top)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 12)
            }
            .contentMargins(.horizontal, horizontalPadding)
            .id(isLandscape)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    private func labelCard(icon: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
            Text(title)
                .font(.subheadline)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func previewText(for entry: LogEntry) -> String {
        if entry.audioFileName != nil {
            return String(localized: "dashboard.item.audioRecording")
        } else {
            return (entry.aiText?.isEmpty == false ? entry.aiText : entry.text) ?? ""
        }
    }
}

#Preview {
    let store = DataStore()
    return NavigationStack { DashboardView() }
        .environmentObject(store)
        .frame(width: 844, height: 390) // iPhone landscape preview size
}
