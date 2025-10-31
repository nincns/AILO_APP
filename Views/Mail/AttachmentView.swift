// AILO_APP/Views/Mail/AttachmentView.swift
// SwiftUI component for displaying email attachments
// Phase 4: Integrates with AttachmentManager for file-based storage

import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// SwiftUI view for displaying email attachments
struct AttachmentView: View {
    let attachment: AttachmentEntity
    let attachmentManager: AttachmentManager?
    @State private var attachmentData: Data?
    @State private var isLoading = false
    @State private var loadError: String?
    
    var body: some View {
        HStack(spacing: 12) {
            // Attachment icon
            Image(systemName: attachmentIcon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
            
            // Attachment info
            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.filename)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)
                
                HStack {
                    Text(attachment.mimeType)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Show loading state or error
                if isLoading {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let error = loadError {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 8) {
                if attachment.isInline {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .help("Inline attachment")
                }
                
                // View/Download button
                Button(action: handleAttachmentTap) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Download attachment")
                
                // Quick look button (if supported)
                if canQuickLook {
                    Button(action: handleQuickLook) {
                        Image(systemName: "eye.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            loadAttachmentData()
        }
    }
    
    // MARK: - Computed Properties
    
    private var attachmentIcon: String {
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
    
    private var canQuickLook: Bool {
        let supportedTypes = ["image/", "application/pdf", "text/", "video/", "audio/"]
        return supportedTypes.contains { attachment.mimeType.lowercased().hasPrefix($0) }
    }
    
    // MARK: - Methods
    
    private func loadAttachmentData() {
        guard attachmentData == nil, !isLoading else { return }
        
        isLoading = true
        loadError = nil
        
        Task {
            do {
                let data = try await loadAttachmentDataAsync()
                await MainActor.run {
                    self.attachmentData = data
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadAttachmentDataAsync() async throws -> Data? {
        // Phase 4: Try AttachmentManager first, then fallback to database
        if let manager = attachmentManager {
            if let fileData = manager.loadAttachment(
                accountId: attachment.accountId,
                mailId: attachment.uid,
                attachmentId: attachment.partId
            ) {
                print("✅ DEBUG: Loaded attachment from file system: \(attachment.filename)")
                return fileData
            }
        }
        
        // Fallback to database data
        if let data = attachment.data {
            print("✅ DEBUG: Using attachment data from database: \(attachment.filename)")
            return data
        }
        
        throw AttachmentError.fileNotFound(attachment.filename)
    }
    
    private func handleAttachmentTap() {
        guard let data = attachmentData else {
            loadAttachmentData()
            return
        }
        
        // Save to Downloads folder and open
        saveAndOpenAttachment(data: data)
    }
    
    private func handleQuickLook() {
        guard let data = attachmentData else {
            loadAttachmentData()
            return
        }
        
        // Create temporary file and show in Quick Look
        showInQuickLook(data: data)
    }
    
    private func saveAndOpenAttachment(data: Data) {
        // iOS: Save to Documents directory and show share sheet
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsURL.appendingPathComponent(attachment.filename)
        
        do {
            // Create unique filename if file already exists
            let finalURL = uniqueFileURL(baseURL: fileURL)
            try data.write(to: finalURL)
            
            // iOS: Show activity view controller for sharing
            let activityVC = UIActivityViewController(activityItems: [finalURL], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
            
            print("✅ DEBUG: Attachment saved and shared: \(finalURL.path)")
        } catch {
            print("❌ ERROR: Failed to save attachment: \(error)")
            loadError = "Failed to save: \(error.localizedDescription)"
        }
    }
    
    private func showInQuickLook(data: Data) {
        // iOS: Create temporary file for Quick Look
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(attachment.filename)
        
        do {
            try data.write(to: tempURL)
            
            // iOS: Show activity view controller with Quick Look option
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(activityVC, animated: true)
            }
            
            print("✅ DEBUG: Attachment opened with system apps: \(tempURL.path)")
        } catch {
            print("❌ ERROR: Failed to show in Quick Look: \(error)")
            loadError = "Quick Look failed: \(error.localizedDescription)"
        }
    }
    
    private func uniqueFileURL(baseURL: URL) -> URL {
        var url = baseURL
        var counter = 1
        
        while FileManager.default.fileExists(atPath: url.path) {
            let nameWithoutExtension = baseURL.deletingPathExtension().lastPathComponent
            let pathExtension = baseURL.pathExtension
            let newName = pathExtension.isEmpty 
                ? "\(nameWithoutExtension) (\(counter))"
                : "\(nameWithoutExtension) (\(counter)).\(pathExtension)"
            
            url = baseURL.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }
        
        return url
    }
}

// MARK: - Container View for Multiple Attachments

/// Container view that shows all attachments for a mail
struct AttachmentsListView: View {
    let attachments: [AttachmentEntity]
    let attachmentManager: AttachmentManager?
    
    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "paperclip")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    // Total size
                    let totalSize = attachments.reduce(0) { $0 + $1.sizeBytes }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(UIColor.systemGroupedBackground))
                
                Divider()
                
                // List of attachments
                ForEach(attachments.indices, id: \.self) { index in
                    AttachmentView(
                        attachment: attachments[index],
                        attachmentManager: attachmentManager
                    )
                    .padding(.horizontal)
                    
                    if index < attachments.count - 1 {
                        Divider()
                            .padding(.horizontal)
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .cornerRadius(8)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        AttachmentView(
            attachment: AttachmentEntity(
                accountId: UUID(),
                folder: "INBOX",
                uid: "123",
                partId: "1",
                filename: "document.pdf",
                mimeType: "application/pdf",
                sizeBytes: 1024 * 500, // 500 KB
                data: Data()
            ),
            attachmentManager: nil as AttachmentManager?
        )
        
        AttachmentView(
            attachment: AttachmentEntity(
                accountId: UUID(),
                folder: "INBOX", 
                uid: "124",
                partId: "1",
                filename: "image.jpg",
                mimeType: "image/jpeg",
                sizeBytes: 1024 * 200, // 200 KB
                data: Data(),
                isInline: true
            ),
            attachmentManager: nil as AttachmentManager?
        )
    }
    .padding()
}