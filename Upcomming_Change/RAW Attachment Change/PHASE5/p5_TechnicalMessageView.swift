// AILO_APP/Views/Mail/TechnicalMessageView_Phase5.swift
// PHASE 5: Technical Message View
// Complete technical view with categorized headers and RAW body

import SwiftUI

// MARK: - Technical Message View

/// Phase 5: Complete technical view for email inspection
public struct TechnicalMessageView: View {
    
    let rawMessage: String
    @State private var headers: [EmailHeader] = []
    @State private var categorizedHeaders: [String: [EmailHeader]] = [:]
    @State private var bodyText: String = ""
    @State private var expandedCategories: Set<String> = ["Essential"]
    
    public init(rawMessage: String) {
        self.rawMessage = rawMessage
    }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Technical header banner
                technicalBanner
                
                // Message statistics
                messageStats
                
                Divider()
                
                // Categorized headers
                categorizedHeadersView
                
                Divider()
                
                // RAW body
                rawBodyView
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            parseMessage()
        }
    }
    
    // MARK: - Components
    
    @ViewBuilder
    private var technicalBanner: some View {
        HStack {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Technical View")
                    .font(.headline)
                    .foregroundColor(.orange)
                
                Text("RFC822 Original Message")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Copy all button
            Button(action: copyAll) {
                Label("Copy All", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(.systemOrange).opacity(0.1))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private var messageStats: some View {
        HStack(spacing: 24) {
            statItem(label: "Headers", value: "\(headers.count)")
            statItem(label: "Body Size", value: formatSize(bodyText.count))
            statItem(label: "Total Size", value: formatSize(rawMessage.count))
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var categorizedHeadersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Headers by Category")
                .font(.headline)
            
            ForEach(Array(categorizedHeaders.keys.sorted()), id: \.self) { category in
                if let headers = categorizedHeaders[category] {
                    headerCategoryView(category: category, headers: headers)
                }
            }
        }
    }
    
    @ViewBuilder
    private func headerCategoryView(category: String, headers: [EmailHeader]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Category header with expand/collapse
            Button(action: { toggleCategory(category) }) {
                HStack {
                    Image(systemName: expandedCategories.contains(category) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    
                    Text(category)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text("(\(headers.count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            // Headers (if expanded)
            if expandedCategories.contains(category) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(headers) { header in
                        headerRow(header: header)
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func headerRow(header: EmailHeader) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header name
            Text(header.name)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(header.isImportant ? .blue : .secondary)
            
            // Header value (decoded)
            Text(TechnicalHeaderParser.decodeEncodedWord(header.value))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            
            // Security indicator
            if header.isSecurityRelated {
                Label("Security Header", systemImage: "checkmark.shield")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var rawBodyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Message Body")
                    .font(.headline)
                
                Spacer()
                
                Button(action: copyBody) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
            
            ScrollView(.horizontal, showsIndicators: true) {
                Text(bodyText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(8)
            }
            .frame(minHeight: 200)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Methods
    
    private func parseMessage() {
        let parsed = TechnicalHeaderParser.parse(rawMessage: rawMessage)
        self.headers = parsed.headers
        self.categorizedHeaders = TechnicalHeaderParser.categorize(headers: parsed.headers)
        self.bodyText = parsed.body
    }
    
    private func toggleCategory(_ category: String) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }
    
    private func copyAll() {
        copyToClipboard(rawMessage)
    }
    
    private func copyBody() {
        copyToClipboard(bodyText)
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        
        print("✅ Copied to clipboard")
    }
    
    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
}

// MARK: - Compact Technical Header View

/// Simplified technical header view for inline display
public struct CompactTechnicalHeaderView: View {
    
    let headers: [EmailHeader]
    @State private var showAll: Bool = false
    
    public init(headers: [EmailHeader]) {
        self.headers = headers
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toggle button
            Button(action: { showAll.toggle() }) {
                HStack {
                    Image(systemName: showAll ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    
                    Text("Technical Headers")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    Text("(\(headers.count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            
            // Headers (if shown)
            if showAll {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(headers.prefix(10)) { header in
                        HStack(alignment: .top) {
                            Text(header.name + ":")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                                .frame(width: 100, alignment: .trailing)
                            
                            Text(TechnicalHeaderParser.decodeEncodedWord(header.value))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                    
                    if headers.count > 10 {
                        Text("... and \(headers.count - 10) more")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 100)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Usage Documentation

/*
 TECHNICAL MESSAGE VIEW USAGE (Phase 5)
 =======================================
 
 FULL TECHNICAL VIEW:
 ```swift
 NavigationView {
     TechnicalMessageView(rawMessage: rawRFC822)
         .navigationTitle("Technical Details")
 }
 ```
 
 COMPACT HEADER VIEW:
 ```swift
 VStack {
     // Normal content
     Text(message.subject)
     
     // Expandable technical headers
     CompactTechnicalHeaderView(headers: parsedHeaders)
 }
 ```
 
 WITH TOGGLE:
 ```swift
 struct MessageView: View {
     @State private var showTechnical = false
     
     var body: some View {
         VStack {
             Toggle("Show Technical View", isOn: $showTechnical)
             
             if showTechnical {
                 TechnicalMessageView(rawMessage: raw)
             } else {
                 // Normal view
             }
         }
     }
 }
 ```
 
 FEATURES:
 - Categorized headers (Essential, Routing, Authentication, etc.)
 - Expandable/collapsible categories
 - Syntax highlighting for important headers
 - Security header indicators
 - Copy to clipboard
 - Message statistics (header count, size)
 - Monospaced fonts for technical content
 - Decoded header values (RFC 2047)
 */
