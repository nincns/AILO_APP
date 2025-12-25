// Views/Journey/JourneyPhotoPicker.swift
import SwiftUI
import PhotosUI

struct JourneyPhotoPicker: View {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let onComplete: () -> Void

    @EnvironmentObject private var store: JourneyStore
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isProcessing: Bool = false
    @State private var processedCount: Int = 0
    @State private var totalCount: Int = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isProcessing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Importiere \(processedCount)/\(totalCount)")
                            .font(.headline)

                        Text(String(localized: "journey.attachments.importing"))
                            .foregroundStyle(.secondary)
                    }
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Fehler", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(String(localized: "common.retry")) {
                            errorMessage = nil
                        }
                    }
                } else {
                    PhotosPicker(
                        selection: $selectedItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos]),
                        photoLibrary: .shared()
                    ) {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 60))
                                .foregroundStyle(.blue)

                            Text(String(localized: "journey.attachments.select.photos"))
                                .font(.headline)

                            Text(String(localized: "journey.attachments.select.limit"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .onChange(of: selectedItems) { _, newItems in
                        if !newItems.isEmpty {
                            processSelectedItems(newItems)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle(String(localized: "journey.attachments.photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        isPresented = false
                    }
                    .disabled(isProcessing)
                }
            }
        }
    }

    private func processSelectedItems(_ items: [PhotosPickerItem]) {
        isProcessing = true
        totalCount = items.count
        processedCount = 0

        Task {
            var successCount = 0
            var lastError: Error?

            for item in items {
                do {
                    // Lade Daten
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        continue
                    }

                    // Ermittle Dateinamen
                    let filename = generateFilename(for: item)

                    // Erstelle Attachment
                    let attachment = JourneyAttachmentService.createAttachment(
                        nodeId: nodeId,
                        filename: filename,
                        data: data
                    )

                    // Speichere
                    try await store.addAttachment(attachment, withData: data)
                    successCount += 1

                } catch {
                    lastError = error
                    print("❌ Photo import failed: \(error)")
                }

                await MainActor.run {
                    processedCount += 1
                }
            }

            await MainActor.run {
                isProcessing = false

                if successCount > 0 {
                    onComplete()
                    isPresented = false
                } else if let error = lastError {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func generateFilename(for item: PhotosPickerItem) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        // Ermittle Extension basierend auf supportedContentTypes
        let ext: String
        if let type = item.supportedContentTypes.first {
            if type.conforms(to: .jpeg) || type.conforms(to: .heic) {
                ext = "jpg"
            } else if type.conforms(to: .png) {
                ext = "png"
            } else if type.conforms(to: .gif) {
                ext = "gif"
            } else if type.conforms(to: .movie) || type.conforms(to: .quickTimeMovie) {
                ext = "mov"
            } else if type.conforms(to: .mpeg4Movie) {
                ext = "mp4"
            } else {
                ext = type.preferredFilenameExtension ?? "bin"
            }
        } else {
            ext = "jpg"
        }

        return "photo_\(timestamp).\(ext)"
    }
}

#Preview {
    JourneyPhotoPicker(
        isPresented: .constant(true),
        nodeId: UUID(),
        onComplete: {}
    )
    .environmentObject(JourneyStore.shared)
}
