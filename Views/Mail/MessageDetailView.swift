// MessageDetailView.swift - Detailed view for reading email messages
// OPTIMIERT: Nutzt BodyContentProcessor für initiale Bereinigung + filterTechnicalHeaders für UI-Toggle
import SwiftUI
import WebKit

// MARK: - Message Detail View
// 🚀 PERFORMANCE FIX: This view now loads pre-processed content directly from storage
// The MailSyncEngine handles all MIME parsing, transfer encoding decoding, and content processing
// BodyContentProcessor handles final display preparation (Schritt 2)
// filterTechnicalHeaders provides optional UI toggle for technical details

struct MessageDetailView: View {
    let mail: MessageHeaderEntity
    let onDelete: ((MessageHeaderEntity) -> Void)?
    let onToggleFlag: ((MessageHeaderEntity) -> Void)?
    let onToggleRead: ((MessageHeaderEntity) -> Void)?
    
    @State private var isLoadingBody: Bool = false
    @State private var bodyText: String = ""
    @State private var isHTML: Bool = false
    @State private var attachments: [AttachmentEntity] = []
    @State private var tempFiles: [URL] = []
    @State private var errorMessage: String? = nil
    @State private var showTechnicalHeaders: Bool = false
    @State private var rawBodyText: String = ""  // NEU
    
    @Environment(\.dismiss) private var dismiss
    
    // Convenience initializer for use without actions
    init(mail: MessageHeaderEntity, onDelete: ((MessageHeaderEntity) -> Void)? = nil, onToggleFlag: ((MessageHeaderEntity) -> Void)? = nil, onToggleRead: ((MessageHeaderEntity) -> Void)? = nil) {
        self.mail = mail
        self.onDelete = onDelete
        self.onToggleFlag = onToggleFlag
        self.onToggleRead = onToggleRead
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                // Mail header information
                mailHeaderSection
                
                Divider()
                
                // Mail body content
                if isLoadingBody {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Inhalt wird geladen...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.vertical, 20)
                } else {
                    mailBodySection
                }
                
                // Show refresh action if no content available
                if bodyText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty && !isLoadingBody {
                    VStack(spacing: 12) {
                        Text("Der Mail-Inhalt ist noch nicht verfügbar. Versuchen Sie eine Aktualisierung.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button(action: refreshBodyContent) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Inhalt aktualisieren")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                
                // Attachments section
                if !attachments.isEmpty {
                    Divider()
                    attachmentsSection
                }
                
                Spacer(minLength: 20)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(minHeight: geometry.size.height)
            }
        }
        .navigationTitle("Nachricht")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: replyAction) {
                        Label("Antworten", systemImage: "arrowshape.turn.up.left")
                    }
                    Button(action: forwardAction) {
                        Label("Weiterleiten", systemImage: "arrowshape.turn.up.right")
                    }
                    Divider()
                    Button(action: toggleFlagAction) {
                        Label(
                            mail.flags.contains("\\Flagged") ? "Markierung entfernen" : "Markieren",
                            systemImage: mail.flags.contains("\\Flagged") ? "flag.slash" : "flag"
                        )
                    }
                    Button(action: toggleReadAction) {
                        Label(
                            mail.flags.contains("\\Seen") ? "Als ungelesen markieren" : "Als gelesen markieren",
                            systemImage: mail.flags.contains("\\Seen") ? "envelope.badge" : "envelope.open"
                        )
                    }
                    Divider()
                    Button(action: { showTechnicalHeaders.toggle() }) {
                        Label(
                            showTechnicalHeaders ? "Technische Details ausblenden" : "Technische Details anzeigen",
                            systemImage: "info.circle"
                        )
                    }
                    Button(role: .destructive, action: deleteAction) {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            loadMailBody()
        }
        .onDisappear {
            cleanupTempFiles()
        }
    }
    
    @ViewBuilder
    private var mailHeaderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Subject
            Text(mail.subject.isEmpty ? "Kein Betreff" : mail.subject)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            
            // From, Date, and Flags - Optimiertes Grid-Layout
            VStack(alignment: .leading, spacing: 8) {
                let parsedFrom = parseFromAddress(mail.from)
                
                // Von (Absender) - Zeile
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // Icon + Label
                    HStack(spacing: 6) {
                        Image(systemName: "person.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                        Text("Von:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                    }
                    
                    // Wert (Name)
                    VStack(alignment: .leading, spacing: 2) {
                        if let displayName = parsedFrom.name, !displayName.isEmpty {
                            Text(displayName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        } else if let email = parsedFrom.email {
                            Text(email)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        } else {
                            Text(mail.from)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                        
                        // E-Mail-Adresse (nur wenn Name vorhanden)
                        if let displayName = parsedFrom.name, !displayName.isEmpty,
                           let email = parsedFrom.email {
                            Text(email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                
                // Datum - Zeile
                if let date = mail.date {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        // Icon + Label
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                            Text("Datum:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .leading)
                        }
                        
                        // Wert
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                    }
                }
            }
            
            // Mail status indicators
            HStack(spacing: 16) {
                if !mail.flags.contains("\\Seen") {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                        Text("Ungelesen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if mail.flags.contains("\\Flagged") {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                        Text("Markiert")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var mailBodySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTechnicalHeaders {
                // RAW RFC822 Ansicht
                rawMailView
            } else {
                // Normale Ansicht
                if isHTML {
                    MailHTMLWebView(html: bodyText)
                        .frame(minHeight: 200)
                } else {
                    Text(bodyText)
                        .font(.body)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }
    
    /// RAW Mail Ansicht für technische Analyse
    @ViewBuilder
    private var rawMailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Info-Banner
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(.blue)
                Text("RAW RFC822 Format")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            // RAW Content
            ScrollView {
                Text(rawBodyText.isEmpty ? "RAW-Content nicht verfügbar" : rawBodyText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(rawBodyText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(minHeight: 200)
        }
    }
    
    @ViewBuilder
    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("Anhänge")
                    .font(.headline)
                    .fontWeight(.medium)
            }
            
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    AttachmentRowView(
                        attachment: attachment,
                        tempFileURL: index < tempFiles.count ? tempFiles[index] : nil
                    )
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadMailBody() {
        isLoadingBody = true
        errorMessage = nil
        
        Task {
            do {
                // 🚀 FIRST: Try to load cached mail body from local storage
                print("📱 Loading cached mail body immediately...")
                var bodyLoaded = false
                
                if let cachedText = try MailRepository.shared.loadCachedBody(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                    // Check if we actually have content (not just empty cache entry)
                    if !cachedText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        // ✅ RAW aus DB holen, dann MIME parsen + BodyContentProcessor
                        let mime = MIMEParser().parse(rawBodyBytes: nil, rawBodyString: cachedText, contentType: nil, charset: nil)
                        let displayContent = BodyContentProcessor.selectDisplayContent(html: mime.html, text: mime.text)
                        
                        await MainActor.run {
                            bodyText = displayContent.content
                            isHTML = displayContent.isHTML
                            isLoadingBody = false
                        }
                        print("✅ Cached mail body loaded and processed: \(displayContent.content.prefix(100))...")
                        
                        // RAW body für technische Ansicht laden
                        if let dao = MailRepository.shared.dao,
                           let bodyEntity = try? dao.bodyEntity(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                            await MainActor.run {
                                rawBodyText = bodyEntity.rawBody ?? "RAW-Content nicht verfügbar"
                            }
                        }
                        
                        bodyLoaded = true
                    }
                }
                
                // 🔄 If no cached body or empty cache, try regular repository method
                if !bodyLoaded {
                    print("🔧 Fallback: trying regular repository getBody...")
                    if let text = try MailRepository.shared.getBody(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                        if !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                            // ✅ RAW aus DB holen, dann MIME parsen + BodyContentProcessor
                            let mime = MIMEParser().parse(rawBodyBytes: nil, rawBodyString: text, contentType: nil, charset: nil)
                            let displayContent = BodyContentProcessor.selectDisplayContent(html: mime.html, text: mime.text)
                            
                            await MainActor.run {
                                bodyText = displayContent.content
                                isHTML = displayContent.isHTML
                                isLoadingBody = false
                            }
                            
                            // RAW body für technische Ansicht laden
                            if let dao = MailRepository.shared.dao,
                               let bodyEntity = try? dao.bodyEntity(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                                await MainActor.run {
                                    rawBodyText = bodyEntity.rawBody ?? "RAW-Content nicht verfügbar"
                                }
                            }
                            
                            bodyLoaded = true
                            print("✅ Body loaded from repository and processed")
                        }
                    }
                }
                
                // 🚫 No content available - trigger EXPLICIT body fetch for this specific mail
                if !bodyLoaded {
                    await MainActor.run {
                        bodyText = "Inhalt wird vom Server geladen..."
                        isHTML = false
                        isLoadingBody = true
                    }
                    print("⚠️ No mail body content available in cache or storage")
                    
                    // 🔄 Trigger FULL sync to fetch missing body for this specific message
                    print("🔄 Triggering full sync to fetch missing body for UID: \(mail.uid)")
                    MailRepository.shared.sync(accountId: mail.accountId, folders: [mail.folder])
                    
                    // Wait for sync completion with monitoring
                    await waitForSyncCompletion()
                    
                    // Try loading the body again after full sync
                    await loadMailBodyAfterSync()
                }
                
                // Load attachments in parallel (doesn't block body display)
                await loadAttachments()
                
            } catch {
                MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to load mail body: \(error)")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    bodyText = ""
                    isHTML = false
                    isLoadingBody = false
                }
            }
        }
    }
    
    /// Load mail body after full sync
    private func loadMailBodyAfterSync() async {
        print("📧 Attempting to load body after full sync...")
        
        do {
            var bodyLoaded = false
            
            // Try repository method after full sync
            if let rawText = try MailRepository.shared.getBody(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                if !rawText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                    // ✅ RAW aus DB holen, dann MIME parsen + BodyContentProcessor
                    let mime = MIMEParser().parse(rawBodyBytes: nil, rawBodyString: rawText, contentType: nil, charset: nil)
                    let displayContent = BodyContentProcessor.selectDisplayContent(html: mime.html, text: mime.text)
                    
                    await MainActor.run {
                        bodyText = displayContent.content
                        isHTML = displayContent.isHTML
                        isLoadingBody = false
                    }
                    
                    // RAW body für technische Ansicht laden
                    if let dao = MailRepository.shared.dao,
                       let bodyEntity = try? dao.bodyEntity(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                        await MainActor.run {
                            rawBodyText = bodyEntity.rawBody ?? "RAW-Content nicht verfügbar"
                        }
                    }
                    
                    bodyLoaded = true
                    print("✅ Body loaded and processed after full sync")
                }
            }
            
            if !bodyLoaded {
                await MainActor.run {
                    bodyText = "Mail-Inhalt konnte nicht geladen werden. Versuchen Sie 'Inhalt aktualisieren'."
                    isHTML = false
                    isLoadingBody = false
                }
                print("⚠️ Body still not available after full sync")
            }
            
        } catch {
            MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to load body after full sync: \(error)")
            await MainActor.run {
                errorMessage = "Fehler beim Laden des Inhalts: \(error.localizedDescription)"
                bodyText = ""
                isHTML = false
                isLoadingBody = false
            }
        }
    }
    
    /// Refresh body content by triggering sync and reloading
    private func refreshBodyContent() {
        print("🔄 User requested body content refresh")
        
        // Start loading state
        isLoadingBody = true
        errorMessage = nil
        bodyText = "Inhalt wird vom Server geladen..."
        
        Task {
            // Trigger FULL sync to fetch missing body
            print("🔄 Triggering FULL sync for missing body content...")
            MailRepository.shared.sync(accountId: mail.accountId, folders: [mail.folder])
            
            // Monitor sync state instead of fixed wait time
            await waitForSyncCompletion()
            
            // Try loading again after sync completes
            await loadMailBodyAfterSync()
        }
    }
    
    /// Wait for sync to complete by monitoring sync state
    private func waitForSyncCompletion() async {
        let maxWaitTime: TimeInterval = 10.0 // Maximum 10 seconds
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            // Check if we can load body content now
            do {
                if let text = try MailRepository.shared.getBody(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) {
                    if !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                        print("✅ Body content became available during sync wait")
                        return
                    }
                }
            } catch {
                print("⚠️ Error checking body during sync wait: \(error)")
            }
            
            // Wait 0.5 seconds before checking again
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        
        print("⏱️ Sync wait completed after \(Date().timeIntervalSince(startTime))s")
    }
    
    private func loadAttachments() async {
        guard let dao = MailRepository.shared.dao else { return }
        
        do {
            // Try to load attachments - cast to expected type
            if let loadedAttachments = try dao.attachments(accountId: mail.accountId, folder: mail.folder, uid: mail.uid) as? [AttachmentEntity] {
                var tempURLs: [URL] = []
                
                // Create temporary files for attachments that have data
                for attachment in loadedAttachments {
                    if let data = attachment.data {
                        let filename = attachment.filename.isEmpty ? "\(attachment.partId).dat" : attachment.filename
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                        
                        do {
                            try data.write(to: tempURL)
                            tempURLs.append(tempURL)
                        } catch {
                            MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to write temp file for attachment: \(error)")
                            tempURLs.append(FileManager.default.temporaryDirectory.appendingPathComponent("attachment_error.txt"))
                        }
                    } else {
                        // Placeholder for attachments without data
                        tempURLs.append(FileManager.default.temporaryDirectory.appendingPathComponent("no_data.txt"))
                    }
                }
                
                await MainActor.run {
                    self.attachments = loadedAttachments
                    self.tempFiles = tempURLs
                }
            }
        } catch {
            MailLogger.shared.error(.FETCH, accountId: mail.accountId, "Failed to load attachments: \(error)")
        }
    }
    
    private func cleanupTempFiles() {
        for tempFile in tempFiles {
            try? FileManager.default.removeItem(at: tempFile)
        }
        tempFiles.removeAll()
    }
    
    private func replyAction() {
        // TODO: Implement reply functionality
        print("🔄 Reply to mail: \(mail.subject)")
    }
    
    private func forwardAction() {
        // TODO: Implement forward functionality
        print("➡️ Forward mail: \(mail.subject)")
    }
    
    private func toggleFlagAction() {
        onToggleFlag?(mail)
        print("🏴 Toggle flag for mail: \(mail.subject)")
    }
    
    private func toggleReadAction() {
        onToggleRead?(mail)
        print("📧 Toggle read status for mail: \(mail.subject)")
    }
    
    private func deleteAction() {
        onDelete?(mail)
        print("🗑️ Delete mail: \(mail.subject)")
        dismiss()
    }
    
    // MARK: - Helper Functions

    /// Parse "Display Name <email@domain.com>" format into components
    private func parseFromAddress(_ from: String) -> (name: String?, email: String?) {
        // Pattern: "Name <email>" or just "email"
        let trimmed = from.trimmingCharacters(in: .whitespaces)
        
        // Check for "Name <email>" format
        if let openBracket = trimmed.lastIndex(of: "<"),
           let closeBracket = trimmed.lastIndex(of: ">"),
           openBracket < closeBracket {
            
            let name = String(trimmed[..<openBracket])
                .trimmingCharacters(in: .whitespaces)
            let email = String(trimmed[trimmed.index(after: openBracket)..<closeBracket])
                .trimmingCharacters(in: .whitespaces)
            
            return (name.isEmpty ? nil : name, email)
        }
        
        // If no brackets, check if it's just an email
        if trimmed.contains("@") {
            return (nil, trimmed)
        }
        
        // Fallback: treat entire string as name
        return (trimmed, nil)
    }
    
}

// MARK: - Supporting Views

private struct MailHTMLWebView: UIViewRepresentable {
    let html: String
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.isScrollEnabled = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Der HTML-Content ist bereits durch BodyContentProcessor bereinigt
        // Minimales Styling für optimale Darstellung
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: \(UITraitCollection.current.userInterfaceStyle == .dark ? "#ffffff" : "#000000");
                    background-color: transparent;
                    margin: 0;
                    padding: 0;
                    word-wrap: break-word;
                }
                img {
                    max-width: 100% !important;
                    height: auto !important;
                }
                table {
                    max-width: 100% !important;
                    table-layout: fixed !important;
                }
                pre {
                    white-space: pre-wrap;
                    word-wrap: break-word;
                }
                a {
                    color: \(UITraitCollection.current.userInterfaceStyle == .dark ? "#0A84FF" : "#007AFF");
                }
            </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
        
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}

private struct AttachmentRowView: View {
    let attachment: AttachmentEntity
    let tempFileURL: URL?
    
    var body: some View {
        HStack {
            Image(systemName: iconForAttachment)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename.isEmpty ? attachment.partId : attachment.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                
                if let data = attachment.data {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            if let tempURL = tempFileURL {
                ShareLink(item: tempURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var iconForAttachment: String {
        let filename = attachment.filename.lowercased()
        if filename.hasSuffix(".pdf") {
            return "doc.fill"
        } else if filename.hasSuffix(".jpg") || filename.hasSuffix(".jpeg") || filename.hasSuffix(".png") || filename.hasSuffix(".gif") {
            return "photo.fill"
        } else if filename.hasSuffix(".doc") || filename.hasSuffix(".docx") {
            return "doc.text.fill"
        } else if filename.hasSuffix(".xls") || filename.hasSuffix(".xlsx") {
            return "tablecells.fill"
        } else if filename.hasSuffix(".zip") || filename.hasSuffix(".rar") {
            return "archivebox.fill"
        } else {
            return "paperclip"
        }
    }
}

#Preview {
    NavigationStack {
        MessageDetailView(
            mail: MessageHeaderEntity(
                accountId: UUID(),
                folder: "INBOX",
                uid: "123",
                from: "john@example.com",
                subject: "Important Meeting Tomorrow",
                date: Date(),
                flags: []
            )
        )
    }
}
