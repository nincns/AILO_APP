// Views/Journey/JourneyDocumentPicker.swift
import SwiftUI
import UniformTypeIdentifiers

struct JourneyDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let onComplete: () -> Void

    @EnvironmentObject private var store: JourneyStore

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .pdf,
            .plainText,
            .rtf,
            .rtfd,
            .html,
            .spreadsheet,
            .presentation,
            .image,
            .movie,
            .audio,
            .archive,
            .data
        ]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: JourneyDocumentPicker

        init(_ parent: JourneyDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task {
                var successCount = 0

                for url in urls {
                    do {
                        // Mit asCopy: true ist die Datei bereits lokal kopiert
                        // Security Scope ist nicht nötig für lokale Kopien
                        let needsSecurityScope = url.startAccessingSecurityScopedResource()
                        defer {
                            if needsSecurityScope {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }

                        // Lade Daten
                        let data = try Data(contentsOf: url)
                        let filename = url.lastPathComponent

                        // Erstelle Attachment
                        let attachment = JourneyAttachmentService.createAttachment(
                            nodeId: parent.nodeId,
                            filename: filename,
                            data: data
                        )

                        // Speichere
                        try await parent.store.addAttachment(attachment, withData: data)
                        successCount += 1

                    } catch {
                        print("❌ Document import failed: \(error)")
                    }
                }

                await MainActor.run {
                    if successCount > 0 {
                        parent.onComplete()
                    }
                    parent.isPresented = false
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Document Picker Wrapper View

/// Wrapper für sheet-Präsentation mit Navigation
struct JourneyDocumentPickerSheet: View {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let onComplete: () -> Void

    @EnvironmentObject private var store: JourneyStore

    var body: some View {
        JourneyDocumentPicker(
            isPresented: $isPresented,
            nodeId: nodeId,
            onComplete: onComplete
        )
        .environmentObject(store)
    }
}
