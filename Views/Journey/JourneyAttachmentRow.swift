// Views/Journey/JourneyAttachmentRow.swift
import SwiftUI

struct JourneyAttachmentRow: View {
    let attachment: JourneyAttachment

    @EnvironmentObject private var store: JourneyStore
    @State private var thumbnailImage: UIImage?

    private var isImage: Bool {
        JourneyAttachmentService.isImage(mimeType: attachment.mimeType)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail / Icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .frame(width: 50, height: 50)

                if let image = thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: JourneyAttachmentService.icon(for: attachment.mimeType))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.filename)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(JourneyAttachmentService.formattedSize(attachment.fileSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .foregroundStyle(.secondary)

                    Text(attachment.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard isImage else { return }

        do {
            if let data = try await store.getBlobData(hash: attachment.dataHash),
               let thumbnailData = JourneyAttachmentService.generateThumbnail(from: data, maxSize: 100),
               let image = UIImage(data: thumbnailData) {
                thumbnailImage = image
            }
        } catch {
            print("❌ Thumbnail load failed: \(error)")
        }
    }
}

#Preview {
    List {
        JourneyAttachmentRow(
            attachment: JourneyAttachment(
                nodeId: UUID(),
                filename: "vacation_photo.jpg",
                mimeType: "image/jpeg",
                fileSize: 2048000,
                dataHash: "abc123"
            )
        )

        JourneyAttachmentRow(
            attachment: JourneyAttachment(
                nodeId: UUID(),
                filename: "report.pdf",
                mimeType: "application/pdf",
                fileSize: 512000,
                dataHash: "def456"
            )
        )

        JourneyAttachmentRow(
            attachment: JourneyAttachment(
                nodeId: UUID(),
                filename: "budget.xlsx",
                mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                fileSize: 128000,
                dataHash: "ghi789"
            )
        )
    }
    .environmentObject(JourneyStore.shared)
}
