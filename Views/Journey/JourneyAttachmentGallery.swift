// Views/Journey/JourneyAttachmentGallery.swift
import SwiftUI

struct JourneyAttachmentGallery: View {
    let attachments: [JourneyAttachment]
    let onDelete: ((JourneyAttachment) -> Void)?
    let onTap: ((JourneyAttachment) -> Void)?

    @EnvironmentObject private var store: JourneyStore

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)
    ]

    init(
        attachments: [JourneyAttachment],
        onDelete: ((JourneyAttachment) -> Void)? = nil,
        onTap: ((JourneyAttachment) -> Void)? = nil
    ) {
        self.attachments = attachments
        self.onDelete = onDelete
        self.onTap = onTap
    }

    var body: some View {
        if attachments.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "journey.attachments.empty"), systemImage: "paperclip")
            } description: {
                Text(String(localized: "journey.attachments.add"))
            }
            .frame(height: 150)
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(attachments) { attachment in
                    JourneyAttachmentThumbnail(
                        attachment: attachment,
                        onDelete: onDelete != nil ? { onDelete?(attachment) } : nil
                    )
                    .onTapGesture {
                        onTap?(attachment)
                    }
                }
            }
        }
    }
}

// MARK: - Thumbnail View

struct JourneyAttachmentThumbnail: View {
    let attachment: JourneyAttachment
    let onDelete: (() -> Void)?

    @EnvironmentObject private var store: JourneyStore
    @State private var thumbnailImage: UIImage?
    @State private var isLoading: Bool = true

    private var isImage: Bool {
        JourneyAttachmentService.isImage(mimeType: attachment.mimeType)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    thumbnailContent
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Delete Button
            if let onDelete = onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 2)
                }
                .offset(x: 6, y: -6)
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if isLoading {
            ProgressView()
        } else if let image = thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            VStack(spacing: 4) {
                Image(systemName: JourneyAttachmentService.icon(for: attachment.mimeType))
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text(attachment.filename)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func loadThumbnail() async {
        guard isImage else {
            isLoading = false
            return
        }

        do {
            if let data = try await store.getBlobData(hash: attachment.dataHash),
               let thumbnailData = JourneyAttachmentService.generateThumbnail(from: data, maxSize: 200),
               let image = UIImage(data: thumbnailData) {
                thumbnailImage = image
            }
        } catch {
            print("❌ Thumbnail load failed: \(error)")
        }

        isLoading = false
    }
}

#Preview {
    JourneyAttachmentGallery(
        attachments: [
            JourneyAttachment(
                nodeId: UUID(),
                filename: "photo.jpg",
                mimeType: "image/jpeg",
                fileSize: 1024000,
                dataHash: "abc123"
            ),
            JourneyAttachment(
                nodeId: UUID(),
                filename: "document.pdf",
                mimeType: "application/pdf",
                fileSize: 2048000,
                dataHash: "def456"
            ),
            JourneyAttachment(
                nodeId: UUID(),
                filename: "spreadsheet.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileSize: 512000,
                dataHash: "ghi789"
            )
        ],
        onDelete: { _ in },
        onTap: { _ in }
    )
    .padding()
    .environmentObject(JourneyStore.shared)
}
