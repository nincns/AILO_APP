import SwiftUI
import Foundation

/// Context-based Pre-Prompt Picker
/// Shows only prompts relevant to the given context
struct PrePromptPicker: View {
    let context: PrePromptContext
    @Binding var selectedId: UUID?
    let onSelect: (AIPrePromptPreset) -> Void

    @State private var presets: [AIPrePromptPreset] = []
    @Environment(\.dismiss) private var dismiss

    /// Filtered presets for the given context
    private var filteredPresets: [AIPrePromptPreset] {
        presets
            .filter { $0.context == context || $0.context == .general }
            .sorted { lhs, rhs in
                // Context-specific first, then by sortOrder
                if lhs.context == context && rhs.context != context { return true }
                if lhs.context != context && rhs.context == context { return false }
                // Then defaults first
                if lhs.isDefault && !rhs.isDefault { return true }
                if !lhs.isDefault && rhs.isDefault { return false }
                return lhs.sortOrder < rhs.sortOrder
            }
    }

    var body: some View {
        NavigationView {
            List {
                if filteredPresets.isEmpty {
                    emptyState
                } else {
                    // Context-specific presets
                    let contextSpecific = filteredPresets.filter { $0.context == context }
                    if !contextSpecific.isEmpty {
                        Section(header: Label(context.localizedName, systemImage: context.icon)) {
                            ForEach(contextSpecific) { preset in
                                presetRow(preset)
                            }
                        }
                    }

                    // General presets (fallback)
                    let generalPresets = filteredPresets.filter { $0.context == .general }
                    if !generalPresets.isEmpty {
                        Section(header: Label(
                            String(localized: "preprompt.category.general"),
                            systemImage: "text.bubble"
                        )) {
                            ForEach(generalPresets) { preset in
                                presetRow(preset)
                            }
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
            .onAppear(perform: loadPresets)
        }
    }

    // MARK: - Views

    private func presetRow(_ preset: AIPrePromptPreset) -> some View {
        Button {
            selectedId = preset.id
            onSelect(preset)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.icon)
                    .foregroundStyle(selectedId == preset.id ? .blue : .secondary)
                    .frame(width: 24)

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

                if selectedId == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
        .buttonStyle(.plain)
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

    // MARK: - Helpers

    private func loadPresets() {
        if let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
           let arr = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) {
            presets = arr
        }
    }
}

// MARK: - Convenience Modifier

extension View {
    /// Shows a pre-prompt picker sheet for the given context
    func prePromptPicker(
        isPresented: Binding<Bool>,
        context: PrePromptContext,
        selectedId: Binding<UUID?> = .constant(nil),
        onSelect: @escaping (AIPrePromptPreset) -> Void
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            PrePromptPicker(
                context: context,
                selectedId: selectedId,
                onSelect: onSelect
            )
        }
    }
}

// MARK: - Helper to get default preset for context

extension Array where Element == AIPrePromptPreset {
    /// Returns the default preset for the given context, or nil if none
    func defaultPreset(for context: PrePromptContext) -> AIPrePromptPreset? {
        // First try context-specific default
        if let contextDefault = first(where: { $0.context == context && $0.isDefault }) {
            return contextDefault
        }
        // Fall back to general default
        if let generalDefault = first(where: { $0.context == .general && $0.isDefault }) {
            return generalDefault
        }
        // Fall back to first context-specific
        if let first = first(where: { $0.context == context }) {
            return first
        }
        // Fall back to first general
        return first(where: { $0.context == .general })
    }
}

// MARK: - Load helper

func loadPrePromptPresets() -> [AIPrePromptPreset] {
    if let data = UserDefaults.standard.data(forKey: kAIPresetsKey),
       let arr = try? JSONDecoder().decode([AIPrePromptPreset].self, from: data) {
        return arr
    }
    return []
}
