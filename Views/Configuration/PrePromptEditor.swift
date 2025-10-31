import SwiftUI
struct PrePromptEditor: View {
    @Binding var prePrompt: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(footer: Text("preprompts.editor.footer")) {
                TextEditor(text: $prePrompt)
                    .frame(minHeight: 160)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }
        .navigationTitle(Text("preprompts.editor.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("preprompts.toolbar.done") {
                    UserDefaults.standard.set(prePrompt, forKey: kAIPrePrompt)
                    dismiss()
                }
            }
        }
        .onDisappear {
            // Persist beim Schließen
            UserDefaults.standard.set(prePrompt, forKey: kAIPrePrompt)
        }
    }
}
