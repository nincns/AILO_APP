// AILO_APP/Views/Mail/AttachmentDetailView.swift
// Phase 5: Detailed attachment viewer with Phase 4 file-system integration
// Supports preview, download, and metadata display

import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import Combine
import UIKit

/// Detailed view for individual attachments
struct AttachmentDetailView: View {
    let attachment: AttachmentEntity
    
    @StateObject private var viewModel = AttachmentDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showingQuickLook = false
    @State private var quickLookURL: URL?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with file info
                attachmentHeader
                
                Divider()
                
                // Preview or metadata section
                if viewModel.isLoading {
                    loadingView
                } else if let error = viewModel.error {
                    errorView(error: error)
                } else {
                    contentView
                }
                
                Divider()
                
                // Action buttons
                actionButtons
            }
        }
        .navigationTitle("Attachment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            Task {
                await viewModel.loadAttachmentData(attachment: attachment)
            }
        }
        .quickLookPreview($quickLookURL)
    }
    
    // MARK: - Header Section
    
    @ViewBuilder
    private var attachmentHeader: some View {
        VStack(spacing: 12) {
            // File icon
            Image(systemName: fileIcon)
                .font(.system(size: 48))
                .foregroundColor(iconColor)
            
            // File name
            Text(attachment.filename)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            
            // File details
            VStack(spacing: 8) {
                HStack {
                    Label("Type", systemImage: "doc.text")
                    Spacer()
                    Text(attachment.mimeType)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Label("Size", systemImage: "externaldrive")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                        .foregroundColor(.secondary)
                }
                
                if attachment.isInline {
                    HStack {
                        Label("Type", systemImage: "photo.badge.plus")
                        Spacer()
                        Text("Inline Attachment")
                            .foregroundColor(.blue)
                    }
                }
                
                // Phase 4: Show storage location
                HStack {
                    Label("Storage", systemImage: "folder")
                    Spacer()
                    if attachment.filePath != nil {
                        Text("File System")
                            .foregroundColor(.green)
                    } else if attachment.data != nil {
                        Text("Database")
                            .foregroundColor(.orange)
                    } else {
                        Text("Unknown")
                            .foregroundColor(.red)
                    }
                }
                
                // Metadata from Phase 3
                if let contentId = attachment.contentId {
                    HStack {
                        Label("Content ID", systemImage: "tag")
                        Spacer()
                        Text(contentId)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                if let checksum = attachment.checksum {
                    HStack {
                        Label("Checksum", systemImage: "checkmark.shield")
                        Spacer()
                        Text(String(checksum.prefix(8)) + "...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    // MARK: - Content Section
    
    @ViewBuilder
    private var contentView: some View {
        ScrollView {
            if attachment.mimeType.lowercased().hasPrefix("image/") {
                imagePreview
            } else if attachment.mimeType.lowercased().hasPrefix("text/") {
                textPreview
            } else {
                genericPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var imagePreview: some View {
        if let data = viewModel.attachmentData,
           let uiImage = UIImage(data: data) {
            VStack(spacing: 12) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 400)
                    .clipped()
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                
                // Image metadata
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image Details")
                        .font(.headline)
                    
                    HStack {
                        Text("Dimensions:")
                        Spacer()
                        Text("\(Int(uiImage.size.width)) × \(Int(uiImage.size.height))")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Color Space:")
                        Spacer()
                        Text("sRGB") // UIImage doesn't expose colorSpace like NSImage
                            .foregroundColor(.secondary)
                    }
                }
                .font(.subheadline)
                .padding()
                .background(Color(UIColor.systemGroupedBackground))
                .cornerRadius(8)
            }
            .padding()
        } else {
            Text("Unable to display image")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private var textPreview: some View {
        if let data = viewModel.attachmentData,
           let textContent = String(data: data, encoding: .utf8) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Text Preview")
                    .font(.headline)
                    .padding(.horizontal)
                
                ScrollView {
                    Text(textContent)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(UIColor.systemBackground))
                .cornerRadius(8)
                .frame(maxHeight: 400)
            }
            .padding()
        } else {
            Text("Unable to display text content")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private var genericPreview: some View {
        VStack(spacing: 16) {
            Image(systemName: fileIcon)
                .font(.system(size: 64))
                .foregroundColor(iconColor)
            
            Text("Preview not available")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("This file type cannot be previewed directly. Use Quick Look or download the file to view its contents.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading attachment...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func errorView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            
            Text("Unable to load attachment")
                .font(.headline)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Quick Look button
            Button(action: openInQuickLook) {
                Label("Quick Look", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.attachmentData == nil)
            
            // Download button
            Button(action: downloadAttachment) {
                Label("Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.attachmentData == nil)
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
    }
    
    // MARK: - Computed Properties
    
    private var fileIcon: String {
        switch attachment.mimeType.lowercased() {
        case let type where type.hasPrefix("image/"):
            return "photo"
        case let type where type.hasPrefix("video/"):
            return "video"
        case let type where type.hasPrefix("audio/"):
            return "music.note"
        case "application/pdf":
            return "doc.text"
        case let type where type.contains("word"):
            return "doc.text"
        case let type where type.contains("excel"), let type where type.contains("sheet"):
            return "tablecells"
        case let type where type.contains("powerpoint"), let type where type.contains("presentation"):
            return "rectangle.on.rectangle"
        case "application/zip", "application/x-zip-compressed":
            return "archivebox"
        default:
            return "doc"
        }
    }
    
    private var iconColor: Color {
        switch attachment.mimeType.lowercased() {
        case let type where type.hasPrefix("image/"):
            return .green
        case let type where type.hasPrefix("video/"):
            return .blue
        case let type where type.hasPrefix("audio/"):
            return .purple
        case "application/pdf":
            return .red
        default:
            return .gray
        }
    }
    
    // MARK: - Methods
    
    private func loadAttachmentData() {
        Task {
            await viewModel.loadAttachmentData(attachment: attachment)
        }
    }
    
    private func openInQuickLook() {
        guard let data = viewModel.attachmentData else { return }
        
        // Create temporary file for Quick Look
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(attachment.filename)
        
        do {
            try data.write(to: tempURL)
            quickLookURL = tempURL
            showingQuickLook = true
        } catch {
            print("❌ ERROR: Failed to create temporary file for Quick Look: \(error)")
        }
    }
    
    private func downloadAttachment() {
        guard let data = viewModel.attachmentData else { return }
        
        // iOS: Save to Documents directory and show share sheet
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsPath.appendingPathComponent(attachment.filename)
        
        do {
            try data.write(to: fileURL)
            print("✅ DEBUG: Attachment saved to: \(fileURL.path)")
            
            // iOS: Show activity view controller for sharing
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
        } catch {
            print("❌ ERROR: Failed to save attachment: \(error)")
        }
    }
}

// MARK: - ViewModel

/// View model for attachment detail view
@MainActor
class AttachmentDetailViewModel: ObservableObject {
    @Published var attachmentData: Data?
    @Published var isLoading = false
    @Published var error: String?
    
    func loadAttachmentData(attachment: AttachmentEntity) async {
        isLoading = true
        error = nil
        
        // Phase 4: Use attachment data directly from database
        if let data = attachment.data {
            attachmentData = data
            print("✅ DEBUG: Loaded attachment from database: \(attachment.filename)")
        } else {
            error = "Attachment data not found"
            print("❌ ERROR: Attachment data not found for: \(attachment.filename)")
        }
        
        isLoading = false
    }
}

// MARK: - Preview

#Preview {
    AttachmentDetailView(
        attachment: AttachmentEntity(
            accountId: UUID(),
            folder: "INBOX",
            uid: "test-123",
            partId: "1",
            filename: "example.pdf",
            mimeType: "application/pdf",
            sizeBytes: 1024 * 500, // 500 KB
            data: Data(),
            contentId: "content-123",
            isInline: false,
            filePath: "/path/to/file",
            checksum: "abc123def456"
        )
    )
}