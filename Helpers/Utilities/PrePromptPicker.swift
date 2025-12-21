import SwiftUI
import Foundation

/// Hierarchical Pre-Prompt Picker
/// Allows browsing the folder structure and selecting a preset
struct PrePromptPicker: View {
    let rootID: UUID?                      // Start folder (nil = root)
    @Binding var selectedPresetID: UUID?
    var onSelect: ((AIPrePromptPreset) -> Void)?

    @StateObject private var manager = PrePromptCatalogManager.shared
    @State private var currentFolderID: UUID?
    @State private var navigationPath: [UUID] = []
    @Environment(\.dismiss) private var dismiss

    init(
        rootID: UUID? = nil,
        selectedPresetID: Binding<UUID?> = .constant(nil),
        onSelect: ((AIPrePromptPreset) -> Void)? = nil
    ) {
        self.rootID = rootID
        self._selectedPresetID = selectedPresetID
        self.onSelect = onSelect
        self._currentFolderID = State(initialValue: rootID)
    }

    var body: some View {
        NavigationView {
            List {
                // Breadcrumb if not at root
                if currentFolderID != nil {
                    breadcrumbSection
                }

                // Content
                if manager.children(of: currentFolderID).isEmpty {
                    emptyState
                } else {
                    ForEach(manager.children(of: currentFolderID)) { item in
                        if item.isFolder {
                            folderRow(item)
                        } else {
                            presetRow(item)
                        }
                    }
                }
            }
            .navigationTitle(Text("preprompt.picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "preprompt.picker.cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Views

    private var breadcrumbSection: some View {
        Section {
            Button {
                navigateUp()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.caption)

                    if let folderID = currentFolderID {
                        let path = manager.path(to: folderID)
                        ForEach(Array(path.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.name)
                                .font(.caption)
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("preprompt.picker.empty")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("preprompt.picker.empty.hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func folderRow(_ item: PrePromptMenuItem) -> some View {
        Button {
            navigationPath.append(item.id)
            currentFolderID = item.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(.blue)
                    .frame(width: 28)

                Text(item.name)
                    .foregroundStyle(.primary)

                Spacer()

                let childCount = manager.children(of: item.id).count
                if childCount > 0 {
                    Text("\(childCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func presetRow(_ item: PrePromptMenuItem) -> some View {
        Button {
            if let presetID = item.presetID,
               let preset = manager.preset(withID: presetID) {
                selectedPresetID = preset.id
                onSelect?(preset)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .foregroundStyle(selectedPresetID == item.presetID ? .blue : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if let presetID = item.presetID,
                       let preset = manager.preset(withID: presetID) {
                        Text(preset.text.prefix(60) + (preset.text.count > 60 ? "..." : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if let presetID = item.presetID,
                   let preset = manager.preset(withID: presetID),
                   preset.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }

                if selectedPresetID == item.presetID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func navigateUp() {
        if navigationPath.isEmpty {
            currentFolderID = rootID
        } else {
            navigationPath.removeLast()
            currentFolderID = navigationPath.last ?? rootID
        }
    }
}

// MARK: - Convenience Modifier

extension View {
    /// Shows a pre-prompt picker sheet
    func prePromptPicker(
        isPresented: Binding<Bool>,
        rootID: UUID? = nil,
        selectedID: Binding<UUID?> = .constant(nil),
        onSelect: @escaping (AIPrePromptPreset) -> Void
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            PrePromptPicker(
                rootID: rootID,
                selectedPresetID: selectedID,
                onSelect: onSelect
            )
        }
    }
}

// MARK: - Quick Picker (flat list from folder)

/// A simpler picker that shows all presets from a folder (recursively)
struct PrePromptQuickPicker: View {
    let folderID: UUID?
    @Binding var selectedPresetID: UUID?
    var onSelect: ((AIPrePromptPreset) -> Void)?

    @StateObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    private var allPresets: [AIPrePromptPreset] {
        manager.presets(in: folderID)
    }

    var body: some View {
        NavigationView {
            List {
                if allPresets.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("preprompt.picker.empty")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(allPresets) { preset in
                        Button {
                            selectedPresetID = preset.id
                            onSelect?(preset)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.icon)
                                    .foregroundStyle(selectedPresetID == preset.id ? .blue : .secondary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    Text(preset.text.prefix(60) + (preset.text.count > 60 ? "..." : ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Spacer()

                                if preset.isDefault {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption)
                                }

                                if selectedPresetID == preset.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(Text("preprompt.picker.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "preprompt.picker.cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }
}
