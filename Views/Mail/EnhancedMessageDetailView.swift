// AILO_APP/Views/Mail/EnhancedMessageDetailView.swift
// Phase 5: Optimized message detail view using database metadata
// No re-parsing, direct display based on content_type, lazy attachment loading

import SwiftUI
import WebKit
import Combine
import UIKit

/// Enhanced message detail view that leverages Phase 3-4 improvements
struct EnhancedMessageDetailView: View {
    let messageHeader: MessageHeaderEntity
    let accountId: UUID
    let folder: String
    
    @StateObject private var viewModel = MessageDetailViewModel()
    @EnvironmentObject private var mailRepository: MailRepository
    @State private var selectedAttachment: AttachmentEntity?
    @State private var showingAttachmentDetail = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header section
                messageHeaderSection
                
                // Content section (Phase 5: metadata-aware)
                if let bodyData = viewModel.bodyData {
                    messageContentSection(bodyData: bodyData)
                } else if viewModel.isLoading {
                    loadingSection
                } else if let error = viewModel.error {
                    errorSection(error: error)
                } else {
                    emptyContentSection
                }
                
                // Attachments section (Phase 4: file-system aware)
                if !viewModel.attachments.isEmpty {
                    attachmentsSection
                }
                
                Spacer(minLength: 50)
            }
            .padding()
        }
        .navigationTitle(messageHeader.subject)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                messageActions
            }
        }
        .onAppear {
            loadMessageData()
        }
        .sheet(item: $selectedAttachment) { attachment in
            AttachmentDetailView(attachment: attachment)
        }
    }
    
    // MARK: - Header Section
    
    @ViewBuilder
    private var messageHeaderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Subject
            Text(messageHeader.subject)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.leading)
            
            // From
            HStack {
                Image(systemName: "person.circle")
                    .foregroundColor(.secondary)
                Text(messageHeader.from)
                    .font(.subheadline)
                Spacer()
            }
            
            // Date and flags
            HStack {
                if let date = messageHeader.date {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Flag indicators
                HStack(spacing: 4) {
                    ForEach(messageHeader.flags, id: \.self) { flag in
                        flagIndicator(for: flag)
                    }
                }
            }
            
            // Metadata indicators (Phase 5: show processing info)
            if let bodyData = viewModel.bodyData {
                metadataIndicators(for: bodyData)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func flagIndicator(for flag: String) -> some View {
        switch flag {
        case "\\Seen":
            Image(systemName: "envelope.open")
                .font(.caption)
                .foregroundColor(.blue)
        case "\\Flagged":
            Image(systemName: "flag.fill")
                .font(.caption)
                .foregroundColor(.orange)
        case "\\Answered":
            Image(systemName: "arrowshape.turn.up.left")
                .font(.caption)
                .foregroundColor(.green)
        case "\\Draft":
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundColor(.purple)
        default:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func metadataIndicators(for body: EnhancedMessageBodyData) -> some View {
        HStack(spacing: 12) {
            // Content type indicator
            Label(body.isHTML ? "HTML" : "Text", systemImage: body.isHTML ? "code" : "doc.text")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Multipart indicator
            if body.isMultipart {
                Label("Multipart", systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Charset indicator (if not UTF-8)
            if let charset = body.charset?.lowercased(), charset != "utf-8" {
                Label(charset.uppercased(), systemImage: "textformat")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Content Section (Phase 5: Metadata-Aware Display)
    
    @ViewBuilder
    private func messageContentSection(bodyData: EnhancedMessageBodyData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Phase 5: Direct display based on stored content_type
            if bodyData.isHTML, let htmlContent = bodyData.htmlContent {
                htmlContentView(content: htmlContent)
                .frame(minHeight: 200)
            } else if let textContent = bodyData.textContent {
                textContentView(content: textContent)
            } else {
                Text("No content available")
                    .foregroundColor(.secondary)
                    .font(.body)
                    .padding()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func htmlContentView(content: String) -> some View {
        // Phase 5: Use WebKit for HTML content without re-processing
        WebView(htmlContent: content, 
                baseURL: nil,
                inlineImages: viewModel.attachments.filter { $0.isInline })
    }
    
    @ViewBuilder
    private func textContentView(content: String) -> some View {
        // Phase 5: Direct text display with smart formatting
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(content)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 200)
    }
    
    // MARK: - Loading and Error States
    
    @ViewBuilder
    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading message content...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func errorSection(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(.red)
            Text("Failed to load message")
                .font(.headline)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private var emptyContentSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("No content")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Attachments Section (Phase 4: File-System Aware)
    
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Attachments", systemImage: "paperclip")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("\(viewModel.attachments.count) file\(viewModel.attachments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Attachment list with lazy loading
            LazyVStack(spacing: 8) {
                ForEach(viewModel.attachments.indices, id: \.self) { index in
                    EnhancedAttachmentRowView(
                        attachment: viewModel.attachments[index],
                        onTap: { selectedAttachment = viewModel.attachments[index] }
                    )
                    
                    if index < viewModel.attachments.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Toolbar Actions
    
    @ViewBuilder
    private var messageActions: some View {
        HStack {
            // Mark as read/unread
            Button(action: toggleReadStatus) {
                Image(systemName: messageHeader.flags.contains("\\Seen") ? "envelope.open" : "envelope")
            }
            .help(messageHeader.flags.contains("\\Seen") ? "Mark as unread" : "Mark as read")
            
            // Flag/unflag
            Button(action: toggleFlagged) {
                Image(systemName: messageHeader.flags.contains("\\Flagged") ? "flag.fill" : "flag")
            }
            .help(messageHeader.flags.contains("\\Flagged") ? "Remove flag" : "Add flag")
            
            // Delete
            Button(action: deleteMessage) {
                Image(systemName: "trash")
            }
            .help("Delete message")
        }
    }
    
    // MARK: - Methods
    
    private func loadMessageData() {
        Task {
            await viewModel.loadMessage(
                accountId: accountId,
                folder: folder,
                uid: messageHeader.uid,
                mailRepository: mailRepository
            )
        }
    }
    
    private func toggleReadStatus() {
        // Implementation for toggling read status
        print("Toggle read status for message: \(messageHeader.uid)")
    }
    
    private func toggleFlagged() {
        // Implementation for toggling flagged status
        print("Toggle flagged status for message: \(messageHeader.uid)")
    }
    
    private func deleteMessage() {
        // Implementation for deleting message
        print("Delete message: \(messageHeader.uid)")
    }
}

// MARK: - ViewModel

/// Enhanced view model that uses Phase 3-4 optimizations
@MainActor
class MessageDetailViewModel: ObservableObject {
    @Published var bodyData: EnhancedMessageBodyData?
    @Published var attachments: [AttachmentEntity] = []
    @Published var isLoading = false
    @Published var error: String?
    
    func loadMessage(accountId: UUID, folder: String, uid: String, mailRepository: MailRepository) async {
        isLoading = true
        error = nil
        
        do {
            // Phase 5: Load enhanced body data with metadata
            if let enhancedBody = try await loadEnhancedBodyData(
                accountId: accountId,
                folder: folder,
                uid: uid,
                mailRepository: mailRepository
            ) {
                bodyData = enhancedBody
            }
            
            // Phase 4: Load attachments with file-system awareness
            attachments = try await loadAttachments(
                accountId: accountId,
                folder: folder,
                uid: uid,
                mailRepository: mailRepository
            )
            
        } catch {
            self.error = error.localizedDescription
            print("❌ ERROR: Failed to load message data: \(error)")
        }
        
        isLoading = false
    }
    
    /// Phase 5: Load enhanced body data using stored metadata
    private func loadEnhancedBodyData(accountId: UUID, folder: String, uid: String, mailRepository: MailRepository) async throws -> EnhancedMessageBodyData? {
        guard let dao = mailRepository.dao else {
            throw MessageDetailError.daoNotAvailable
        }
        
        // Try enhanced body entity first (Phase 3 data with metadata)
        if let bodyEntity = try dao.bodyEntity(accountId: accountId, folder: folder, uid: uid) {
            return EnhancedMessageBodyData(from: bodyEntity)
        }
        
        // Fallback to simple body string (legacy data)
        if let bodyString = try dao.body(accountId: accountId, folder: folder, uid: uid) {
            let isHTML = ContentAnalyzer.detectHTMLContent(bodyString)
            return EnhancedMessageBodyData(
                textContent: isHTML ? nil : bodyString,
                htmlContent: isHTML ? bodyString : nil,
                contentType: isHTML ? "text/html" : "text/plain",
                charset: "utf-8",
                transferEncoding: "7bit",
                isMultipart: false,
                rawSize: bodyString.count,
                processedAt: nil
            )
        }
        
        return nil
    }
    
    /// Phase 4: Load attachments with file-system support
    private func loadAttachments(accountId: UUID, folder: String, uid: String, mailRepository: MailRepository) async throws -> [AttachmentEntity] {
        guard let dao = mailRepository.dao else {
            throw MessageDetailError.daoNotAvailable
        }
        
        return try dao.attachments(accountId: accountId, folder: folder, uid: uid)
    }
}

// MARK: - Supporting Types

/// Enhanced body data with metadata (Phase 5)
struct EnhancedMessageBodyData {
    let textContent: String?
    let htmlContent: String?
    let contentType: String
    let charset: String?
    let transferEncoding: String?
    let isMultipart: Bool
    let rawSize: Int?
    let processedAt: Date?
    
    var isHTML: Bool {
        contentType.lowercased().contains("html")
    }
    
    init(textContent: String?, htmlContent: String?, contentType: String, charset: String?, transferEncoding: String?, isMultipart: Bool, rawSize: Int?, processedAt: Date?) {
        self.textContent = textContent
        self.htmlContent = htmlContent
        self.contentType = contentType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.isMultipart = isMultipart
        self.rawSize = rawSize
        self.processedAt = processedAt
    }
    
    init(from bodyEntity: MessageBodyEntity) {
        self.textContent = bodyEntity.text
        self.htmlContent = bodyEntity.html
        self.contentType = bodyEntity.contentType ?? "text/plain"
        self.charset = bodyEntity.charset
        self.transferEncoding = bodyEntity.transferEncoding
        self.isMultipart = bodyEntity.isMultipart
        self.rawSize = bodyEntity.rawSize
        self.processedAt = bodyEntity.processedAt
    }
}

/// Enhanced attachment row with lazy loading (Phase 4)
struct EnhancedAttachmentRowView: View {
    let attachment: AttachmentEntity
    let onTap: () -> Void
    
    @State private var thumbnailImage: UIImage?
    @State private var isLoadingThumbnail = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail or icon
                Group {
                    if let thumbnail = thumbnailImage {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if isLoadingThumbnail {
                        ProgressView()
                            .scaleEffect(0.5)
                    } else {
                        Image(systemName: attachmentIcon)
                            .foregroundColor(attachmentIconColor)
                    }
                }
                .frame(width: 40, height: 40)
                
                // File info
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    HStack {
                        Text(attachment.mimeType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Phase 4: Show storage location
                    if attachment.filePath != nil {
                        Label("File System", systemImage: "externaldrive")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if attachment.data != nil {
                        Label("Database", systemImage: "internaldrive")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                
                Spacer()
                
                // Inline indicator
                if attachment.isInline {
                    Image(systemName: "photo.badge.plus")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .onAppear {
            loadThumbnailIfNeeded()
        }
    }
    
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
        default:
            return "doc"
        }
    }
    
    private var attachmentIconColor: Color {
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
    
    private func loadThumbnailIfNeeded() {
        guard attachment.mimeType.lowercased().hasPrefix("image/"),
              thumbnailImage == nil,
              !isLoadingThumbnail else { return }
        
        isLoadingThumbnail = true
        
        Task {
            defer { 
                Task { @MainActor in
                    isLoadingThumbnail = false
                }
            }
            
            // Phase 4: Try to load image data from attachment data
            let imageData = attachment.data
            
            if let data = imageData, let image = UIImage(data: data) {
                // Create thumbnail
                let thumbnailSize = CGSize(width: 40, height: 40)
                let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
                
                let thumbnail = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: thumbnailSize))
                }
                
                await MainActor.run {
                    self.thumbnailImage = thumbnail
                }
            }
        }
    }
}

/// Simple WebView for HTML content display
struct WebView: UIViewRepresentable {
    let htmlContent: String
    let baseURL: URL?
    let inlineImages: [AttachmentEntity]
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Phase 5: Load HTML with proper base URL and inline image support
        uiView.loadHTMLString(processedHTMLContent, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    private var processedHTMLContent: String {
        // Phase 5: Process HTML to handle inline images
        var processed = htmlContent
        
        // Replace cid: references with data URLs for inline images
        for attachment in inlineImages {
            if let contentId = attachment.contentId,
               let data = attachment.data {
                let dataURL = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                processed = processed.replacingOccurrences(of: "cid:\(contentId)", with: dataURL)
            }
        }
        
        // Wrap in proper HTML structure if needed
        if !processed.lowercased().contains("<html>") {
            processed = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    body { 
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
                        line-height: 1.6;
                        margin: 16px;
                    }
                    img { max-width: 100%; height: auto; }
                    table { width: 100%; border-collapse: collapse; }
                </style>
            </head>
            <body>
                \(processed)
            </body>
            </html>
            """
        }
        
        return processed
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        // Handle navigation events if needed
    }
}

/// Errors for MessageDetailView
enum MessageDetailError: LocalizedError {
    case daoNotAvailable
    case contentNotFound
    case processingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daoNotAvailable:
            return "Database not available"
        case .contentNotFound:
            return "Message content not found"
        case .processingFailed(let reason):
            return "Processing failed: \(reason)"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        EnhancedMessageDetailView(
            messageHeader: MessageHeaderEntity(
                accountId: UUID(),
                folder: "INBOX",
                uid: "test-123",
                from: "test@example.com",
                subject: "Test Message",
                date: Date(),
                flags: ["\\Seen", "\\Flagged"]
            ),
            accountId: UUID(),
            folder: "INBOX"
        )
    }
    .environmentObject(MailRepository.shared)
}