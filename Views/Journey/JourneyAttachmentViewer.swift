// Views/Journey/JourneyAttachmentViewer.swift
import SwiftUI
import QuickLook
import UIKit

struct JourneyAttachmentViewer: View {
    let attachment: JourneyAttachment

    @EnvironmentObject private var store: JourneyStore
    @Environment(\.dismiss) private var dismiss

    @State private var imageData: Data?
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var tempURL: URL?

    private var isImage: Bool {
        JourneyAttachmentService.isImage(mimeType: attachment.mimeType)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Lade...")
                } else if let error = error {
                    ContentUnavailableView {
                        Label("Fehler", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                } else if isImage, let data = imageData, let uiImage = UIImage(data: data) {
                    // Image Viewer mit Zoom
                    ZoomableImageView(image: uiImage)
                } else if let url = tempURL {
                    // QuickLook für andere Dateitypen
                    QuickLookPreview(url: url)
                } else {
                    ContentUnavailableView {
                        Label("Nicht unterstützt", systemImage: "doc.questionmark")
                    } description: {
                        Text("Dieser Dateityp kann nicht angezeigt werden")
                    }
                }
            }
            .navigationTitle(attachment.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if let data = imageData {
                        ShareLink(
                            item: data,
                            preview: SharePreview(
                                attachment.filename,
                                image: Image(systemName: JourneyAttachmentService.icon(for: attachment.mimeType))
                            )
                        )
                    } else if let url = tempURL {
                        ShareLink(item: url)
                    }
                }
            }
        }
        .task {
            await loadContent()
        }
        .onDisappear {
            // Cleanup temp file
            if let url = tempURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func loadContent() async {
        print("🖼️ Loading attachment: \(attachment.filename), hash: \(attachment.dataHash), isImage: \(isImage)")

        do {
            guard let data = try await store.getBlobData(hash: attachment.dataHash) else {
                print("❌ Blob data not found for hash: \(attachment.dataHash)")
                await MainActor.run {
                    error = "Datei nicht gefunden"
                    isLoading = false
                }
                return
            }

            print("✅ Loaded blob data: \(data.count) bytes")

            await MainActor.run {
                if isImage {
                    print("🖼️ Setting imageData for image type")
                    imageData = data

                    // Verify UIImage can be created
                    if UIImage(data: data) != nil {
                        print("✅ UIImage created successfully")
                    } else {
                        print("❌ Failed to create UIImage from data")
                        error = "Bild konnte nicht geladen werden"
                    }
                } else {
                    // Speichere in Temp-Datei für QuickLook
                    let tempDir = FileManager.default.temporaryDirectory
                    let url = tempDir.appendingPathComponent(UUID().uuidString + "_" + attachment.filename)
                    do {
                        try data.write(to: url)
                        tempURL = url
                        print("✅ Wrote temp file to: \(url)")
                    } catch {
                        print("❌ Failed to write temp file: \(error)")
                        self.error = error.localizedDescription
                    }
                }
                isLoading = false
            }

        } catch {
            print("❌ Error loading blob: \(error)")
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}

// MARK: - Zoomable Image View

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.tag = 100

        scrollView.addSubview(imageView)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        imageView.frame = scrollView.bounds
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            scrollView.viewWithTag(100)
        }
    }
}

// MARK: - QuickLook Preview

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

#Preview {
    JourneyAttachmentViewer(
        attachment: JourneyAttachment(
            nodeId: UUID(),
            filename: "test.pdf",
            mimeType: "application/pdf",
            fileSize: 1024,
            dataHash: "abc123"
        )
    )
    .environmentObject(JourneyStore.shared)
}
