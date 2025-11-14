// AILO_APP/Views/Mail/RawMailToggleView_Phase5.swift
// PHASE 5: RAW Mail Toggle & Technical View
// Allows switching between rendered content and original RFC822 message

import SwiftUI

// MARK: - RAW Mail Toggle View

/// Phase 5: Toggle component for switching between rendered and RAW view
public struct RawMailToggleView: View {
    
    @Binding var showRaw: Bool
    let onToggle: (Bool) -> Void
    
    public init(showRaw: Binding<Bool>, onToggle: @escaping (Bool) -> Void) {
        self._showRaw = showRaw
        self.onToggle = onToggle
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            // Icon indicator
            Image(systemName: showRaw ? "doc.text" : "doc.richtext")
                .foregroundColor(showRaw ? .orange : .blue)
                .font(.title3)
            
            // Toggle switch
            Toggle(isOn: $showRaw) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(showRaw ? "Technical View" : "Normal View")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    Text(showRaw ? "Original RFC822 message" : "Processed content")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: showRaw) { oldValue, newValue in
                onToggle(newValue)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
}

// MARK: - Enhanced Message Detail View with RAW Toggle

/// Phase 5: Complete message detail view with RAW/Normal toggle
public struct EnhancedMessageDetailViewWithToggle: View {
    
    let messageId: UUID
    let accountId: UUID
    let folder: String
    let uid: String
    
    @State private var showRaw: Bool = false
    @State private var processedMessage: ProcessedMessage?
    @State private var rawMessage: String?
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    
    private let service: EnhancedMessageProcessingService
    
    public init(messageId: UUID, accountId: UUID, folder: String, uid: String,
                service: EnhancedMessageProcessingService) {
        self.messageId = messageId
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.service = service
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Toggle bar
            RawMailToggleView(showRaw: $showRaw) { newValue in
                if newValue {
                    loadRawMessage()
                } else {
                    loadProcessedMessage()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Content area
            ScrollView {
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(message: error)
                } else if showRaw {
                    rawContentView
                } else {
                    processedContentView
                }
            }
        }
        .navigationTitle("Message Details")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadProcessedMessage()
        }
    }
    
    // MARK: - Content Views
    
    @ViewBuilder
    private var processedContentView: some View {
        if let message = processedMessage {
            VStack(alignment: .leading, spacing: 16) {
                // Cache indicator
                if message.fromCache {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.green)
                        Text("Loaded from cache (instant)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                }
                
                // HTML or Text content
                if let html = message.htmlContent {
                    HTMLContentDisplayView(html: html)
                } else if let text = message.textContent {
                    Text(text)
                        .font(.body)
                        .padding()
                }
            }
        } else {
            Text("No processed content available")
                .foregroundColor(.secondary)
                .padding()
        }
    }
    
    @ViewBuilder
    private var rawContentView: some View {
        if let raw = rawMessage {
            VStack(alignment: .leading, spacing: 8) {
                // Technical header
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.orange)
                    Text("RFC822 Original Message")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    Spacer()
                    
                    // Copy button
                    Button(action: { copyToClipboard(raw) }) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                }
                .padding()
                .background(Color(.systemOrange).opacity(0.1))
                
                // RAW content (monospaced)
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(raw)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                
                Text("RAW message not available")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button("Load RAW") {
                    loadRawMessage()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading message...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.red)
            
            Text("Error")
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                if showRaw {
                    loadRawMessage()
                } else {
                    loadProcessedMessage()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Data Loading
    
    private func loadProcessedMessage() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let message = try service.getProcessedMessage(messageId: messageId)
                
                await MainActor.run {
                    self.processedMessage = message
                    self.isLoading = false
                    
                    if message == nil {
                        self.errorMessage = "Message not processed yet"
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load message: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadRawMessage() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Get RAW from blob store via service
                let raw = try service.getRawMessage(messageId: messageId)
                
                await MainActor.run {
                    self.rawMessage = raw
                    self.isLoading = false
                    
                    if raw == nil {
                        self.errorMessage = "RAW message not available"
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load RAW: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        
        print("✅ Copied RAW message to clipboard")
    }
}

// MARK: - HTML Content Display

/// Simple HTML display view using WKWebView
struct HTMLContentDisplayView: View {
    let html: String
    
    var body: some View {
        HTMLWebView(html: html)
            .frame(minHeight: 200)
    }
}

#if os(iOS)
import WebKit

struct HTMLWebView: UIViewRepresentable {
    let html: String
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(html, baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        // Handle navigation if needed
    }
}
#endif

// MARK: - Preview Helper

#if DEBUG
struct RawMailToggleView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            VStack {
                RawMailToggleView(showRaw: .constant(false)) { _ in }
                    .padding()
                
                Spacer()
            }
        }
    }
}
#endif

// MARK: - Usage Documentation

/*
 RAW MAIL TOGGLE USAGE (Phase 5)
 ================================
 
 BASIC USAGE:
 ```swift
 EnhancedMessageDetailViewWithToggle(
     messageId: messageId,
     accountId: accountId,
     folder: folder,
     uid: uid,
     service: messageProcessingService
 )
 ```
 
 TOGGLE COMPONENT STANDALONE:
 ```swift
 RawMailToggleView(showRaw: $showRaw) { newValue in
     if newValue {
         // Load RAW
         loadRawMessage()
     } else {
         // Load processed
         loadProcessedMessage()
     }
 }
 ```
 
 INTEGRATION WITH EXISTING VIEW:
 ```swift
 struct MessageDetailView: View {
     @State private var showRaw = false
     
     var body: some View {
         VStack {
             RawMailToggleView(showRaw: $showRaw, onToggle: handleToggle)
             
             if showRaw {
                 // RAW view
             } else {
                 // Normal view
             }
         }
     }
     
     func handleToggle(_ showRaw: Bool) {
         if showRaw {
             loadRawFromBlobStore()
         }
     }
 }
 ```
 
 FEATURES:
 - Toggle between Normal and Technical view
 - Instant switching (no re-processing)
 - RAW from blob store (Phase 4)
 - Copy RAW to clipboard
 - Monospaced font for technical view
 - Cache indicator in normal view
 */
