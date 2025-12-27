// Views/Assistant/AssistantView.swift
// AILO - Setup Assistant Hauptansicht

import SwiftUI

struct AssistantView: View {
    @StateObject private var registry = AssistantModuleRegistry.shared
    @State private var selectedModule: IdentifiableModule?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Header
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 48))
                            .foregroundStyle(.teal.gradient)

                        Text("assistant.welcome.title")
                            .font(.title2.bold())

                        Text("assistant.welcome.subtitle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }

                // Module-Liste
                Section(header: Text("assistant.section.modules")) {
                    ForEach(registry.modules, id: \.id) { module in
                        ModuleRowView(module: module) {
                            selectedModule = IdentifiableModule(id: module.id, module: module)
                        }
                    }
                }

                // Hilfe-Bereich
                Section(header: Text("assistant.section.help")) {
                    Link(destination: URL(string: "https://ailo.network/help")!) {
                        Label("assistant.help.online", systemImage: "questionmark.circle")
                    }

                    Button {
                        // TODO: Feedback Sheet
                    } label: {
                        Label("assistant.help.feedback", systemImage: "envelope")
                    }
                }
            }
            .navigationTitle(Text("assistant.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $selectedModule) { wrapper in
                NavigationStack {
                    wrapper.module.makeView()
                }
            }
        }
    }
}

// MARK: - Module Row View

private struct ModuleRowView: View {
    let module: any AssistantModule
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon
                Image(systemName: module.icon)
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .frame(width: 40, height: 40)
                    .background(Color.teal.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(module.title)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        if module.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.subheadline)
                        }
                    }

                    Text(module.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Identifiable Wrapper für Sheet

struct IdentifiableModule: Identifiable {
    let id: String
    let module: any AssistantModule
}

// MARK: - Preview

#Preview {
    AssistantView()
}
