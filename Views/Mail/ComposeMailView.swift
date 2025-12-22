// ComposeMailView.swift - Enhanced mail composer for AILO_APP
import SwiftUI
import PhotosUI
import WebKit
import Combine

struct ComposeMailView: View {
    @Environment(\.dismiss) private var dismiss

    // MARK: - Reply/Forward Parameters
    var replyToMail: MessageHeaderEntity? = nil
    var replyAll: Bool = false
    var isForward: Bool = false      // Forward mode (vs Reply)
    var originalBody: String = ""
    var originalTo: String = ""      // For Reply All
    var originalCC: String = ""      // For Reply All
    var originalIsHTML: Bool = false // Format der Original-Mail
    var preselectedAccountId: UUID? = nil
    var originalAttachments: [Attachment] = []  // Anhänge aus Original-Mail

    // MARK: - Addressing
    @State private var accounts: [MailAccountConfig] = []
    @State private var activeIDs: Set<UUID> = []
    @State private var selectedAccountId: UUID? = nil

    @State private var to: String = ""
    @State private var cc: String = ""
    @State private var bcc: String = ""
    @State private var subject: String = ""

    // MARK: - Body
    @State private var isHTML: Bool = true  // HTML als Standard für neue Mails
    @State private var textBody: String = ""
    @State private var htmlBody: String = ""

    // MARK: - Pre-Prompt / Prompt Manager Navigation
    @ObservedObject private var catalogManager = PrePromptCatalogManager.shared
    @State private var showPrePromptPicker = false
    @State private var prePromptNavigationPath: [UUID] = []  // Stack: [cookbookID, chapterID, ...]
    @State private var selectedRecipe: PrePromptRecipe? = nil  // Currently selected recipe for AI generation
    @State private var isGenerating: Bool = false
    @State private var showGenerationError: Bool = false
    @State private var generationErrorMessage: String = ""

    // MARK: - Attachments
    struct Attachment: Identifiable, Equatable {
        let id = UUID()
        var data: Data
        var mimeType: String
        var filename: String
    }
    @State private var attachments: [Attachment] = []

    // Pickers
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter: Bool = false

    // Rich Text Editor Controller
    @StateObject private var editorController = RichTextEditorController()

    // Autosave debounce
    @State private var autosaveTask: Task<Void, Never>? = nil

    // Prefill subscription (reply/forward)
    @State private var prefillToken: UUID? = nil

    private let autosaveKey = "compose.autosave"

    // AI Separator markers - visible line that separates AI-editable content from preserved content
    private let aiSeparatorHTML = "<p style=\"color: #999; text-align: center;\">─────── ✨ ───────</p>"
    private let aiSeparatorText = "\n─────── ✨ ───────\n"
    private let aiSeparatorPattern = "─────── ✨ ───────"  // For detection

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compact header section
                VStack(spacing: 0) {
                    // From row with Pre-Prompt picker and HTML toggle
                    HStack {
                        // Left side: Account picker
                        HStack {
                            Text("Von")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 35, alignment: .leading)
                            Picker("", selection: $selectedAccountId) {
                                ForEach(activeAccounts(), id: \.id) { acc in
                                    Text(acc.accountName).tag(acc.id as UUID?)
                                }
                            }
                            .labelsHidden()
                            .scaleEffect(0.9)
                        }
                        .frame(minWidth: 80)

                        Spacer()

                        // Center: AI-Manager Button + Generate Button
                        HStack(spacing: 12) {
                            // AI-Manager Button (wand icon)
                            Button {
                                Task {
                                    await insertAISeparatorAsync()
                                    await MainActor.run {
                                        showPrePromptPicker = true
                                    }
                                }
                            } label: {
                                Image(systemName: selectedRecipe != nil ? "wand.and.stars.inverse" : "wand.and.stars")
                                    .font(.system(size: 18))
                                    .foregroundStyle(selectedRecipe != nil ? .green : .blue)
                                    .frame(width: 36, height: 36)
                                    .background(Color(UIColor.tertiarySystemBackground))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)

                            // Generate Button (only visible when recipe is selected)
                            if selectedRecipe != nil {
                                Button {
                                    generateWithAI()
                                } label: {
                                    Group {
                                        if isGenerating {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        } else {
                                            Image(systemName: "sparkles")
                                                .font(.system(size: 16))
                                        }
                                    }
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(isGenerating ? Color.gray : Color.blue)
                                    .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isGenerating)
                            }
                        }

                        Spacer()

                        // Right side: HTML Toggle
                        HStack(spacing: 4) {
                            Text("HTML")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("", isOn: $isHTML)
                                .labelsHidden()
                                .scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 50)

                    // To row
                    HStack {
                        Text("An")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("Empfänger", text: $to)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.emailAddress)
                            .font(.subheadline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 50)

                    // CC row
                    HStack {
                        Text("CC")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("CC", text: $cc)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.emailAddress)
                            .font(.subheadline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 50)

                    // BCC row (collapsible - only show if has content or tapped)
                    if !bcc.isEmpty {
                        HStack {
                            Text("BCC")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .leading)
                            TextField("BCC", text: $bcc)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .keyboardType(.emailAddress)
                                .font(.subheadline)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)

                        Divider().padding(.leading, 50)
                    }

                    // Subject row
                    HStack {
                        Text("Betreff")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        TextField("Betreff", text: $subject)
                            .textInputAutocapitalization(.sentences)
                            .font(.subheadline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.secondarySystemBackground))

                Divider()

                // Body section
                if isHTML {
                    VStack(spacing: 0) {
                        // Formatting toolbar
                        FormattingToolbar(controller: editorController)

                        Divider()

                        RichTextEditorView(html: $htmlBody, controller: editorController)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    TextEditor(text: $textBody)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .frame(maxHeight: .infinity)
                }

                // Attachments bar (compact)
                if !attachments.isEmpty || true {
                    Divider()
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                            Image(systemName: "photo")
                                .font(.title3)
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.title3)
                        }

                        if !attachments.isEmpty {
                            Divider()
                                .frame(height: 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(attachments) { att in
                                        HStack(spacing: 4) {
                                            Text(att.filename)
                                                .font(.caption)
                                                .lineLimit(1)
                                            Button {
                                                attachments.removeAll { $0.id == att.id }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(UIColor.tertiarySystemBackground))
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                }
            }
            .navigationTitle(String(localized: "app.mail.compose.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "app.common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "app.mail.send")) { sendAndDismiss() }
                        .disabled(!canSend)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {
                        if let data = try? Data(contentsOf: url) {
                            let name = url.lastPathComponent
                            let mime = mimeType(for: url.pathExtension)
                            attachments.append(.init(data: data, mimeType: mime, filename: name))
                        }
                    }
                case .failure:
                    break
                }
            }
            .sheet(isPresented: $showPrePromptPicker) {
                PrePromptCatalogPickerSheet(
                    navigationPath: $prePromptNavigationPath,
                    onSelectRecipe: { recipe in
                        applyRecipe(recipe)
                        showPrePromptPicker = false
                    }
                )
            }
            .alert(String(localized: "compose.ai.error.title"), isPresented: $showGenerationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(generationErrorMessage)
            }
            .onChange(of: photoItems) { _, items in
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            attachments.append(.init(data: data, mimeType: "image/jpeg", filename: "photo.jpg"))
                        }
                    }
                    photoItems.removeAll()
                }
            }
            .onChange(of: to) { _, _ in scheduleAutosave() }
            .onChange(of: cc) { _, _ in scheduleAutosave() }
            .onChange(of: bcc) { _, _ in scheduleAutosave() }
            .onChange(of: subject) { _, _ in scheduleAutosave() }
            .onChange(of: textBody) { _, _ in scheduleAutosave() }
            .onChange(of: htmlBody) { _, _ in scheduleAutosave() }
            .onAppear {
                loadAccounts()

                // Check if this is a reply/forward
                if let mail = replyToMail {
                    prefillForReply(mail: mail)
                }
                // Neue Mail: Felder bleiben leer (kein Autosave laden)
                // Autosave wird nur beim Bearbeiten gespeichert, nicht beim Start geladen

                // Register for prefill (reply/forward)
                prefillToken = ComposePrefillCenter.shared.register { text in
                    Task { @MainActor in
                        if self.textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !self.isHTML {
                            self.textBody = quoted(text)
                        } else if self.htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.isHTML {
                            self.htmlBody = "<blockquote>\(text)</blockquote>"
                        } else {
                            self.textBody += "\n\n" + quoted(text)
                        }
                    }
                }
            }
            .onDisappear {
                if let t = prefillToken { ComposePrefillCenter.shared.unregister(t) }
                autosaveTask?.cancel(); autosaveTask = nil
            }
        }
    }

    // MARK: - Validation
    private var canSend: Bool {
        guard let _ = selectedAccountId else { return false }
        let hasTo = !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSubject = !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = isHTML
            ? !htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTo && hasSubject && hasBody
    }

    // MARK: - Actions
    private func sendAndDismiss() {
        guard let accId = selectedAccountId, let account = accounts.first(where: { $0.id == accId }) else { return }
        // Build draft model with display name for proper From header
        let fromEmail = account.emailAddress
        let fromName = account.displayName ?? account.accountName
        let from = MailSendAddress(fromEmail, name: fromName)
        let toList = splitEmails(to)
        let ccList = splitEmails(cc)
        let bccList = splitEmails(bcc)

        // HTML-Body bereinigen - Editor-Scripts entfernen
        let cleanedHtmlBody: String? = {
            guard isHTML else { return nil }
            var html = htmlBody
            // Alle Script-Tags entfernen (können vom WKWebView-Editor stammen)
            while let scriptRange = html.range(of: "<script[^>]*>[\\s\\S]*?</script>", options: .regularExpression) {
                html.removeSubrange(scriptRange)
            }
            return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : html
        }()

        // Convert attachments to MailSendAttachment
        let mailAttachments = attachments.map { att in
            MailSendAttachment(filename: att.filename, mimeType: att.mimeType, data: att.data)
        }

        let draft = MailDraft(
            from: from,
            to: toList,
            cc: ccList,
            bcc: bccList,
            subject: subject,
            textBody: isHTML ? nil : textBody,
            htmlBody: cleanedHtmlBody,
            attachments: mailAttachments
        )
        // Queue for sending via repository
        _ = MailRepository.shared.send(draft, accountId: accId)
        // Clear autosave
        clearAutosave()
        // Dismiss
        dismiss()
    }

    // MARK: - Accounts
    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "mail.accounts"),
           let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data) {
            self.accounts = list
        } else { self.accounts = [] }
        if let data = UserDefaults.standard.data(forKey: "mail.accounts.active"),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            self.activeIDs = Set(ids)
        } else { self.activeIDs = Set(accounts.map { $0.id }) }
        if selectedAccountId == nil {
            let firstActive = accounts.first { activeIDs.contains($0.id) } ?? accounts.first
            selectedAccountId = firstActive?.id
        }
    }

    private func activeAccounts() -> [MailAccountConfig] {
        accounts.filter { activeIDs.contains($0.id) }
    }

    // MARK: - Autosave
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [to, cc, bcc, subject, textBody, htmlBody, isHTML, selectedAccountId] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            saveAutosave(to: to, cc: cc, bcc: bcc, subject: subject, text: textBody, html: htmlBody, isHTML: isHTML, accId: selectedAccountId)
        }
    }

    private func saveAutosave(to: String, cc: String, bcc: String, subject: String, text: String, html: String, isHTML: Bool, accId: UUID?) {
        let payload: [String: Any] = [
            "to": to, "cc": cc, "bcc": bcc,
            "subject": subject,
            "text": text, "html": html,
            "isHTML": isHTML,
            "accountId": accId?.uuidString ?? ""
        ]
        UserDefaults.standard.set(payload, forKey: autosaveKey)
    }

    private func loadAutosave() {
        guard let dict = UserDefaults.standard.dictionary(forKey: autosaveKey) else { return }
        self.to = dict["to"] as? String ?? ""
        self.cc = dict["cc"] as? String ?? ""
        self.bcc = dict["bcc"] as? String ?? ""
        self.subject = dict["subject"] as? String ?? ""
        self.textBody = dict["text"] as? String ?? ""
        self.htmlBody = dict["html"] as? String ?? ""
        self.isHTML = dict["isHTML"] as? Bool ?? true  // Standard: HTML
        if let idStr = dict["accountId"] as? String, let id = UUID(uuidString: idStr) {
            self.selectedAccountId = id
        }
    }

    private func clearAutosave() { UserDefaults.standard.removeObject(forKey: autosaveKey) }

    // MARK: - Reply/Forward Prefill
    private func prefillForReply(mail: MessageHeaderEntity) {
        // Format der Original-Mail übernehmen
        self.isHTML = originalIsHTML

        // Set account
        if let accId = preselectedAccountId {
            selectedAccountId = accId
        }

        // Anhänge aus Original-Mail übernehmen (bei Reply und Forward)
        if !originalAttachments.isEmpty {
            self.attachments = originalAttachments
        }

        // Build recipients - bei Forward Originalsender in CC
        if isForward {
            // Forward: Empfänger leer, Originalsender in CC
            self.to = ""
            self.cc = mail.from
        } else {
            let myEmail = getMyEmail(for: mail.accountId)

            if replyAll {
                // Reply All: From -> To, original To + CC (minus my email) -> To + CC
                var toRecipients = [mail.from]
                var ccRecipients: [String] = []

                // Parse original To recipients (excluding my email)
                let originalToList = parseEmailList(originalTo)
                for addr in originalToList {
                    if !isSameEmail(addr, myEmail) && !isSameEmail(addr, mail.from) {
                        toRecipients.append(addr)
                    }
                }

                // Parse original CC recipients (excluding my email)
                let originalCCList = parseEmailList(originalCC)
                for addr in originalCCList {
                    if !isSameEmail(addr, myEmail) {
                        ccRecipients.append(addr)
                    }
                }

                self.to = toRecipients.joined(separator: ", ")
                self.cc = ccRecipients.joined(separator: ", ")
            } else {
                // Simple Reply: only to original sender
                self.to = mail.from
            }
        }

        // Subject with Re: or Fwd: prefix
        let originalSubject = mail.subject
        if isForward {
            // Forward: Fwd: prefix
            let lowerSubject = originalSubject.lowercased()
            if lowerSubject.hasPrefix("fwd:") || lowerSubject.hasPrefix("fw:") || lowerSubject.hasPrefix("wg:") {
                self.subject = originalSubject
            } else {
                self.subject = "Fwd: \(originalSubject)"
            }
        } else {
            // Reply: Re: prefix
            if originalSubject.lowercased().hasPrefix("re:") || originalSubject.lowercased().hasPrefix("aw:") {
                self.subject = originalSubject
            } else {
                self.subject = "Re: \(originalSubject)"
            }
        }

        // Quote original body - formatabhängig
        if !originalBody.isEmpty {
            let dateStr = formatDateForQuote(mail.date)
            if originalIsHTML {
                // HTML-Quote mit Blockquote-Styling + Platz für Antwort/Weiterleitung oben
                let action = isForward ? "Weitergeleitete Nachricht" : "schrieb \(mail.from):"
                let header = isForward
                    ? "---------- \(action) ----------<br>Von: \(mail.from)<br>Datum: \(dateStr)<br>Betreff: \(originalSubject)"
                    : (dateStr.isEmpty ? "schrieb \(mail.from):" : "Am \(dateStr) schrieb \(mail.from):")
                let quote = """
                <p><br></p>
                <p>\(header)</p>
                <blockquote style="border-left: 2px solid #ccc; padding-left: 10px; margin-left: 0; color: #555;">
                \(originalBody)
                </blockquote>
                """
                self.htmlBody = quote
            } else {
                // Text-Quote
                if isForward {
                    let forwardHeader = """


                    ---------- Weitergeleitete Nachricht ----------
                    Von: \(mail.from)
                    Datum: \(dateStr)
                    Betreff: \(originalSubject)

                    \(originalBody)
                    """
                    self.textBody = forwardHeader
                } else {
                    // Reply: > Prefix
                    let quote = buildQuote(from: mail.from, date: dateStr, body: originalBody)
                    self.textBody = "\n\n\(quote)"
                }
            }
        }
    }

    private func getMyEmail(for accountId: UUID) -> String {
        if let account = accounts.first(where: { $0.id == accountId }) {
            return account.emailAddress
        }
        return ""
    }

    private func parseEmailList(_ list: String) -> [String] {
        guard !list.isEmpty else { return [] }
        return list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func isSameEmail(_ a: String, _ b: String) -> Bool {
        // Extract email from "Name <email>" format if needed
        let emailA = extractEmail(from: a).lowercased()
        let emailB = extractEmail(from: b).lowercased()
        return emailA == emailB
    }

    private func extractEmail(from str: String) -> String {
        if let start = str.firstIndex(of: "<"), let end = str.firstIndex(of: ">") {
            return String(str[str.index(after: start)..<end])
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatDateForQuote(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy 'um' HH:mm"
        formatter.locale = Locale(identifier: "de_DE")
        return formatter.string(from: date)
    }

    private func buildQuote(from sender: String, date: String, body: String) -> String {
        let header = date.isEmpty ? "schrieb \(sender):" : "Am \(date) schrieb \(sender):"
        let quotedLines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "\(header)\n\(quotedLines)"
    }

    // MARK: - Helpers
    private func splitEmails(_ s: String) -> [MailSendAddress] {
        s.split(separator: ",").map { MailSendAddress(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func quoted(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { "> " + $0 }.joined(separator: "\n")
    }

    private func mimeType(for ext: String) -> String {
        let lower = ext.lowercased()
        switch lower {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Pre-Prompt Application (Recipe from Prompt Manager)
    private func applyRecipe(_ recipe: PrePromptRecipe) {
        // Store the selected recipe for AI generation
        selectedRecipe = recipe
        // Reset navigation for next use
        prePromptNavigationPath.removeAll()
    }

    // MARK: - AI Separator Management

    /// Inserts an AI separator line BELOW the user's text and ABOVE any existing quote
    /// User writes rough notes above → separator → preserved history below
    private func insertAISeparatorIfNeeded() {
        Task {
            await insertAISeparatorAsync()
        }
    }

    /// Async version that fetches current WebView content first
    private func insertAISeparatorAsync() async {
        print("✨ insertAISeparatorAsync started, isHTML: \(isHTML)")

        // For HTML mode: fetch current content from WebView (may differ from htmlBody state)
        var currentBody: String
        if isHTML {
            if let webViewContent = await editorController.getHTMLContent() {
                currentBody = webViewContent
                // Sync state with actual WebView content
                await MainActor.run {
                    htmlBody = webViewContent
                }
                print("✨ Fetched WebView content (\(webViewContent.count) chars): \(webViewContent.prefix(200))...")
            } else {
                currentBody = htmlBody
                print("✨ Using htmlBody state (\(htmlBody.count) chars): \(htmlBody.prefix(200))...")
            }
        } else {
            currentBody = textBody
            print("✨ Using textBody: \(textBody.prefix(200))...")
        }

        // Check if separator already exists
        guard !currentBody.contains(aiSeparatorPattern) else {
            print("✨ AI Separator already present - skipping")
            return
        }

        // Only insert if there's existing content
        guard !currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("✨ No content - separator not needed")
            return
        }

        // Find where the quote/history starts (if any)
        let quoteStartIndex = findQuoteStartIndex(in: currentBody, isHTML: isHTML)
        print("✨ Quote start index found: \(quoteStartIndex != nil ? "YES" : "NO")")

        await MainActor.run {
            if isHTML {
                if let quoteStart = quoteStartIndex {
                    // Insert separator before the quote
                    let userText = String(currentBody[..<quoteStart])
                    let quoteText = String(currentBody[quoteStart...])
                    let newContent = userText + "\n" + aiSeparatorHTML + "\n" + quoteText
                    htmlBody = newContent
                    editorController.setHTMLContent(newContent)
                    print("✨ Inserted separator - userText: \(userText.prefix(50))...")
                } else {
                    // No quote found - append separator at the end
                    let newContent = currentBody + "\n" + aiSeparatorHTML
                    htmlBody = newContent
                    editorController.setHTMLContent(newContent)
                    print("✨ Appended separator at end (no quote found)")
                }
            } else {
                if let quoteStart = quoteStartIndex {
                    let userText = String(currentBody[..<quoteStart])
                    let quoteText = String(currentBody[quoteStart...])
                    textBody = userText + aiSeparatorText + quoteText
                    print("✨ Inserted text separator")
                } else {
                    textBody = currentBody + aiSeparatorText
                    print("✨ Appended text separator at end")
                }
            }
        }
        print("✨ insertAISeparatorAsync completed")
    }

    /// Finds the start index of the quote/history section in the body
    /// Uses EARLIEST match approach to handle nested forwards in replies
    private func findQuoteStartIndex(in body: String, isHTML: Bool) -> String.Index? {
        print("🔍 findQuoteStartIndex - isHTML: \(isHTML), body length: \(body.count)")

        if isHTML {
            var candidates: [(index: String.Index, type: String)] = []

            // Candidate 1: Reply pattern "Am ... schrieb" (most common for replies)
            if let amRange = body.range(of: "Am ", options: .caseInsensitive) {
                let afterAm = body[amRange.upperBound...]
                // Check if "schrieb" appears within ~100 chars
                let checkRange = String(afterAm.prefix(100))
                if checkRange.lowercased().contains("schrieb") {
                    let before = body[..<amRange.lowerBound]
                    if let pRange = before.range(of: "<p", options: [.backwards, .caseInsensitive]) {
                        candidates.append((pRange.lowerBound, "Am...schrieb"))
                    } else {
                        candidates.append((amRange.lowerBound, "Am...schrieb (no <p>)"))
                    }
                }
            }

            // Candidate 2: Forward separator (top-level only)
            if let fwdRange = body.range(of: "---------- Weitergeleitete Nachricht ----------") {
                // Check if NOT inside a blockquote (nested forward)
                let beforeFwd = body[..<fwdRange.lowerBound]
                let openTags = beforeFwd.components(separatedBy: "<blockquote").count - 1
                let closeTags = beforeFwd.components(separatedBy: "</blockquote").count - 1

                if openTags <= closeTags {
                    // Not nested - this is top-level forward
                    let before = body[..<fwdRange.lowerBound]
                    if let pRange = before.range(of: "<p", options: [.backwards, .caseInsensitive]) {
                        candidates.append((pRange.lowerBound, "Forward separator"))
                    } else {
                        candidates.append((fwdRange.lowerBound, "Forward separator (no <p>)"))
                    }
                } else {
                    print("🔍 Forward separator inside blockquote - skipping")
                }
            }

            // Candidate 3: Blockquote (fallback)
            if let bqRange = body.range(of: "<blockquote", options: .caseInsensitive) {
                let before = body[..<bqRange.lowerBound]
                if let pRange = before.range(of: "<p", options: [.backwards, .caseInsensitive]) {
                    candidates.append((pRange.lowerBound, "Blockquote"))
                } else {
                    candidates.append((bqRange.lowerBound, "Blockquote (no <p>)"))
                }
            }

            // Find EARLIEST candidate
            if let earliest = candidates.min(by: { $0.index < $1.index }) {
                print("🔍 Earliest quote marker: '\(earliest.type)' at position \(body.distance(from: body.startIndex, to: earliest.index))")
                return earliest.index
            }

            print("🔍 No HTML quote pattern found")
        } else {
            // Plain text: same logic - find earliest
            var candidates: [(index: String.Index, type: String)] = []

            if let fwdRange = body.range(of: "---------- Weitergeleitete Nachricht ----------") {
                candidates.append((fwdRange.lowerBound, "Forward"))
            }
            if let amRange = body.range(of: "Am ", options: .caseInsensitive),
               String(body[amRange.upperBound...].prefix(100)).contains("schrieb") {
                candidates.append((amRange.lowerBound, "Am...schrieb"))
            }
            if let gtRange = body.range(of: "\n>") {
                candidates.append((gtRange.lowerBound, "> quote"))
            }

            if let earliest = candidates.min(by: { $0.index < $1.index }) {
                print("🔍 Earliest text quote: '\(earliest.type)'")
                return earliest.index
            }
        }
        return nil
    }

    // MARK: - AI Generation
    private func generateWithAI() {
        Task {
            await generateWithAIAsync()
        }
    }

    private func generateWithAIAsync() async {
        guard let recipe = selectedRecipe else {
            print("❌ generateWithAI: No recipe selected")
            return
        }
        guard !isGenerating else {
            print("❌ generateWithAI: Already generating")
            return
        }

        // Generate the pre-prompt from the recipe
        let prePrompt = recipe.generatePrompt(
            from: catalogManager.menuItems,
            presets: catalogManager.presets
        )

        // For HTML mode: fetch current content from WebView first
        var userText: String
        if isHTML {
            if let webViewContent = await editorController.getHTMLContent() {
                userText = webViewContent
                await MainActor.run {
                    htmlBody = webViewContent
                }
                print("🤖 Fetched current WebView content for AI")
            } else {
                userText = htmlBody
            }
        } else {
            userText = textBody
        }

        // Extract original quote to preserve (Reply/Forward history)
        let (textBeforeQuote, originalQuote) = extractQuoteFromBody(userText, isHTML: isHTML)

        // Strip HTML tags from quote for AI context (cleaner input)
        let quoteForContext = originalQuote
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Build full context for AI: user's notes + email history
        // AI needs the history to understand context and write appropriate response
        let fullContextForAI: String
        if quoteForContext.isEmpty {
            fullContextForAI = textBeforeQuote
        } else {
            fullContextForAI = """
            Meine Notizen/Entwurf:
            \(textBeforeQuote)

            --- Bisheriger E-Mail-Verlauf (für Kontext) ---
            \(quoteForContext)
            """
        }

        print("🤖 generateWithAI:")
        print("   - prePrompt: \(prePrompt.prefix(200))...")
        print("   - userNotes: \(textBeforeQuote.prefix(100))...")
        print("   - hasHistory: \(!quoteForContext.isEmpty)")
        print("   - fullContext length: \(fullContextForAI.count) chars")
        print("   - isHTML: \(isHTML)")

        // Check if there's content to process
        guard !prePrompt.isEmpty || !textBeforeQuote.isEmpty else {
            generationErrorMessage = String(localized: "compose.ai.error.empty")
            showGenerationError = true
            print("❌ generateWithAI: Empty prompt and text")
            return
        }

        isGenerating = true

        // Send FULL context to AI (notes + history) so it can write contextual response
        // But we'll only REPLACE the user's draft, keeping the history intact
        AIClient.rewrite(
            baseURL: "",  // Uses selected provider from settings
            port: nil,
            apiKey: nil,
            model: "",
            prePrompt: prePrompt,
            userText: fullContextForAI.isEmpty ? String(localized: "compose.ai.placeholder.text") : fullContextForAI
        ) { result in
            isGenerating = false

            switch result {
            case .success(let generatedText):
                print("✅ AI Response received: \(generatedText.prefix(200))...")
                // Combine AI-generated content with preserved quote
                if isHTML {
                    let htmlContent = "<p>\(generatedText.replacingOccurrences(of: "\n", with: "<br>"))</p>"
                    // Append original quote if exists
                    let finalContent = originalQuote.isEmpty ? htmlContent : htmlContent + "\n" + originalQuote
                    htmlBody = finalContent
                    // Directly inject into WebView to bypass isUserEditing check
                    editorController.setHTMLContent(finalContent)
                    print("   - Updated htmlBody with preserved quote and injected via JS")
                } else {
                    // Append original quote if exists
                    let finalContent = originalQuote.isEmpty ? generatedText : generatedText + "\n\n" + originalQuote
                    textBody = finalContent
                    print("   - Updated textBody with preserved quote")
                }

            case .failure(let error):
                print("❌ AI Error: \(error.localizedDescription)")
                generationErrorMessage = error.localizedDescription
                showGenerationError = true
            }
        }
    }

    /// Extracts the quote portion from the body (for Reply/Forward preservation)
    /// Returns (textBeforeQuote, preservedContentWithoutSeparator)
    /// Priority: 1. AI Separator (✨), 2. Forward separator, 3. Reply patterns
    private func extractQuoteFromBody(_ body: String, isHTML: Bool) -> (String, String) {
        guard !body.isEmpty else { return ("", "") }

        // 🎯 PRIMARY: Check for AI separator first (most reliable)
        if let range = body.range(of: aiSeparatorPattern) {
            let textBefore = String(body[..<range.lowerBound])
            var afterSeparator = String(body[range.upperBound...])

            // Remove the separator line completely from preserved content
            // For HTML: also remove surrounding <p> tags
            if isHTML {
                // Remove </p> that might follow the separator pattern
                if afterSeparator.hasPrefix("</p>") {
                    afterSeparator = String(afterSeparator.dropFirst(4))
                }
                // Clean up leading whitespace/newlines
                afterSeparator = afterSeparator.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // For plain text, just trim
                afterSeparator = afterSeparator.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            print("✨ Found AI separator - user text will be replaced, separator removed")
            return (textBefore.trimmingCharacters(in: .whitespacesAndNewlines), afterSeparator)
        }

        // FALLBACK: Use traditional quote detection if no AI separator
        if isHTML {
            // Forward: "---------- Weitergeleitete Nachricht ----------"
            if let range = body.range(of: "---------- Weitergeleitete Nachricht ----------") {
                let beforeSeparator = String(body[..<range.lowerBound])
                if let pTagRange = beforeSeparator.range(of: "<p>", options: .backwards) {
                    let textBefore = String(body[..<pTagRange.lowerBound])
                    let quote = String(body[pTagRange.lowerBound...])
                    return (textBefore.trimmingCharacters(in: .whitespacesAndNewlines), quote)
                }
                return (beforeSeparator.trimmingCharacters(in: .whitespacesAndNewlines), String(body[range.lowerBound...]))
            }

            // Reply: "<p>Am " followed by date and "schrieb"
            if let range = body.range(of: "<p>Am ", options: .caseInsensitive) {
                let textBefore = String(body[..<range.lowerBound])
                return (textBefore.trimmingCharacters(in: .whitespacesAndNewlines), String(body[range.lowerBound...]))
            }

            // Reply: "schrieb" with blockquote
            if let range = body.range(of: "schrieb", options: .caseInsensitive),
               body.contains("<blockquote") {
                let beforeSchrieb = String(body[..<range.lowerBound])
                if let pTagRange = beforeSchrieb.range(of: "<p>", options: .backwards) {
                    let textBefore = String(body[..<pTagRange.lowerBound])
                    return (textBefore.trimmingCharacters(in: .whitespacesAndNewlines), String(body[pTagRange.lowerBound...]))
                }
            }

        } else {
            // Plain text fallbacks
            if let range = body.range(of: "---------- Weitergeleitete Nachricht ----------") {
                return (String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                        String(body[range.lowerBound...]))
            }

            if let range = body.range(of: "Am ", options: .caseInsensitive),
               body[range.upperBound...].contains("schrieb") {
                return (String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                        String(body[range.lowerBound...]))
            }

            // Quoted lines with ">"
            if body.contains("\n>") || body.hasPrefix(">") {
                let lines = body.components(separatedBy: "\n")
                var textLines: [String] = []
                var quoteLines: [String] = []
                var inQuote = false

                for line in lines {
                    if line.hasPrefix(">") || (inQuote && line.trimmingCharacters(in: .whitespaces).isEmpty) {
                        inQuote = true
                        quoteLines.append(line)
                    } else if !inQuote {
                        textLines.append(line)
                    } else {
                        quoteLines.append(line)
                    }
                }

                return (textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                        quoteLines.joined(separator: "\n"))
            }
        }

        // No quote found - return full text as editable content
        return (body, "")
    }
}

// MARK: - Rich Text Editor Controller
class RichTextEditorController: ObservableObject {
    weak var webView: WKWebView?

    func executeCommand(_ command: String, argument: String? = nil) {
        guard let webView = webView else { return }
        let js: String
        if let arg = argument {
            js = "document.execCommand('\(command)', false, '\(arg)')"
        } else {
            js = "document.execCommand('\(command)', false, null)"
        }
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Directly set HTML content in the editor (bypasses isUserEditing check)
    func setHTMLContent(_ html: String) {
        guard let webView = webView else {
            print("❌ setHTMLContent: No webView")
            return
        }
        // Escape the HTML for JavaScript string
        let escapedHTML = html
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let js = "document.getElementById('editor').innerHTML = '\(escapedHTML)';"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                print("❌ setHTMLContent error: \(error)")
            } else {
                print("✅ setHTMLContent: Content injected via JS")
            }
        }
    }

    /// Get current HTML content from the editor (async, runs on MainActor for WKWebView)
    @MainActor
    func getHTMLContent() async -> String? {
        guard let webView = webView else {
            print("❌ getHTMLContent: No webView")
            return nil
        }
        let js = "document.getElementById('editor').innerHTML"
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("❌ getHTMLContent error: \(error)")
                    continuation.resume(returning: nil)
                } else if let html = result as? String {
                    print("✅ getHTMLContent: Got \(html.count) chars")
                    continuation.resume(returning: html)
                } else {
                    print("❌ getHTMLContent: No result")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func bold() { executeCommand("bold") }
    func italic() { executeCommand("italic") }
    func underline() { executeCommand("underline") }
    func strikethrough() { executeCommand("strikeThrough") }
    func insertOrderedList() { executeCommand("insertOrderedList") }
    func insertUnorderedList() { executeCommand("insertUnorderedList") }
    func indent() { executeCommand("indent") }
    func outdent() { executeCommand("outdent") }
    func insertLink(_ url: String) { executeCommand("createLink", argument: url) }
    func removeFormat() { executeCommand("removeFormat") }
    func setFontName(_ fontName: String) { executeCommand("fontName", argument: fontName) }
    func setFontSize(_ size: Int) { executeCommand("fontSize", argument: String(size)) }

    // Available fonts
    static let availableFonts: [(name: String, value: String)] = [
        ("System", "-apple-system"),
        ("Arial", "Arial"),
        ("Helvetica", "Helvetica"),
        ("Times", "Times New Roman"),
        ("Georgia", "Georgia"),
        ("Courier", "Courier New"),
        ("Verdana", "Verdana")
    ]

    // Font sizes (1-7 scale for execCommand, with display labels)
    static let availableSizes: [(label: String, value: Int)] = [
        ("Klein", 1),
        ("Normal", 3),
        ("Mittel", 4),
        ("Groß", 5),
        ("Sehr groß", 6)
    ]
}

// MARK: - Formatting Toolbar
private struct FormattingToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    @State private var showLinkDialog = false
    @State private var linkURL = ""
    @State private var selectedFont = "System"
    @State private var selectedSize = "Normal"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Font picker
                Menu {
                    ForEach(RichTextEditorController.availableFonts, id: \.value) { font in
                        Button(font.name) {
                            selectedFont = font.name
                            controller.setFontName(font.value)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(selectedFont)
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .frame(minWidth: 60)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(4)
                }
                .foregroundStyle(.primary)

                // Size picker
                Menu {
                    ForEach(RichTextEditorController.availableSizes, id: \.value) { size in
                        Button(size.label) {
                            selectedSize = size.label
                            controller.setFontSize(size.value)
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(selectedSize)
                            .font(.caption)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                    }
                    .frame(minWidth: 50)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(4)
                }
                .foregroundStyle(.primary)

                Divider().frame(height: 20).padding(.horizontal, 4)

                FormatButton(icon: "bold", action: controller.bold)
                FormatButton(icon: "italic", action: controller.italic)
                FormatButton(icon: "underline", action: controller.underline)
                FormatButton(icon: "strikethrough", action: controller.strikethrough)

                Divider().frame(height: 20).padding(.horizontal, 4)

                FormatButton(icon: "list.bullet", action: controller.insertUnorderedList)
                FormatButton(icon: "list.number", action: controller.insertOrderedList)
                FormatButton(icon: "increase.indent", action: controller.indent)
                FormatButton(icon: "decrease.indent", action: controller.outdent)

                Divider().frame(height: 20).padding(.horizontal, 4)

                FormatButton(icon: "link") {
                    showLinkDialog = true
                }
                FormatButton(icon: "clear", action: controller.removeFormat)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 36)
        .background(Color(UIColor.tertiarySystemBackground))
        .alert("Link einfügen", isPresented: $showLinkDialog) {
            TextField("https://", text: $linkURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
            Button("Abbrechen", role: .cancel) {
                linkURL = ""
            }
            Button("Einfügen") {
                if !linkURL.isEmpty {
                    var url = linkURL
                    if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
                        url = "https://" + url
                    }
                    controller.insertLink(url)
                }
                linkURL = ""
            }
        }
    }
}

private struct FormatButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Rich Text Editor View (Editable HTML)
private struct RichTextEditorView: UIViewRepresentable {
    @Binding var html: String
    @ObservedObject var controller: RichTextEditorController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "htmlDidChange")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Register webView with controller for formatting commands
        DispatchQueue.main.async {
            self.controller.webView = webView
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Nur laden wenn sich der Content wirklich geändert hat (nicht durch User-Eingabe)
        guard !context.coordinator.isUserEditing else { return }

        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: #333;
                    margin: 0;
                    padding: 8px;
                    min-height: 100vh;
                    outline: none;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #e0e0e0; background: transparent; }
                }
                blockquote {
                    border-left: 2px solid #ccc;
                    padding-left: 10px;
                    margin: 10px 0;
                    color: #666;
                }
                @media (prefers-color-scheme: dark) {
                    blockquote { color: #999; border-left-color: #555; }
                }
                [contenteditable]:focus { outline: none; }
            </style>
        </head>
        <body contenteditable="true" id="editor">\(html)</body>
        <script>
            const editor = document.getElementById('editor');
            editor.addEventListener('input', function() {
                window.webkit.messageHandlers.htmlDidChange.postMessage(editor.innerHTML);
            });
            editor.addEventListener('focus', function() {
                window.webkit.messageHandlers.htmlDidChange.postMessage('__FOCUS__');
            });
            editor.addEventListener('blur', function() {
                window.webkit.messageHandlers.htmlDidChange.postMessage('__BLUR__');
            });
        </script>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RichTextEditorView
        weak var webView: WKWebView?
        var isUserEditing = false

        init(_ parent: RichTextEditorView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }

            if body == "__FOCUS__" {
                isUserEditing = true
                return
            }
            if body == "__BLUR__" {
                isUserEditing = false
                return
            }

            // HTML hat sich geändert
            DispatchQueue.main.async {
                self.parent.html = body
            }
        }
    }
}

// MARK: - HTML Preview View (Read-only)
private struct HTMLPreviewView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 16px;
                    line-height: 1.5;
                    color: #333;
                    margin: 0;
                    padding: 0;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #e0e0e0; }
                }
                blockquote {
                    border-left: 2px solid #ccc;
                    padding-left: 10px;
                    margin-left: 0;
                    color: #666;
                }
                @media (prefers-color-scheme: dark) {
                    blockquote { color: #999; border-left-color: #555; }
                }
            </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(styledHTML, baseURL: nil)
    }
}

// MARK: - Pre-Prompt Catalog Picker Sheet (uses Prompt Manager / Cookbooks)
private struct PrePromptCatalogPickerSheet: View {
    @Binding var navigationPath: [UUID]
    let onSelectRecipe: (PrePromptRecipe) -> Void

    @ObservedObject private var manager = PrePromptCatalogManager.shared
    @Environment(\.dismiss) private var dismiss

    // Navigation state: nil = cookbook list, UUID = inside a cookbook or chapter
    private var currentCookbookID: UUID? {
        navigationPath.first
    }

    private var currentChapterID: UUID? {
        navigationPath.count > 1 ? navigationPath.last : nil
    }

    // Current title
    private var currentTitle: String {
        if let chapterID = currentChapterID,
           let chapter = manager.recipeMenuItem(withID: chapterID) {
            return chapter.name
        }
        if let cookbookID = currentCookbookID,
           let cookbook = manager.cookbook(withID: cookbookID) {
            return cookbook.name
        }
        return String(localized: "cookbook.title")
    }

    // Check if we can go back
    private var canGoBack: Bool {
        !navigationPath.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                // Back button row (if not at root)
                if canGoBack {
                    Button {
                        navigateBack()
                    } label: {
                        HStack(spacing: 8) {
                            Text("🔙")
                                .font(.body)
                            Text(String(localized: "catalog.recipe.picker.back"))
                                .foregroundStyle(.blue)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color(UIColor.systemBackground))
                }

                // Content based on navigation level
                if currentCookbookID == nil {
                    // Root level: Show cookbooks
                    cookbookListContent
                } else {
                    // Inside a cookbook: Show chapters and recipes
                    cookbookContent
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "common.cancel")) {
                        navigationPath.removeAll()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Cookbook List (Root Level)

    @ViewBuilder
    private var cookbookListContent: some View {
        if manager.cookbooks.isEmpty {
            VStack(spacing: 12) {
                Text("📚")
                    .font(.largeTitle)
                Text("cookbook.list.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        } else {
            ForEach(manager.cookbooks.sorted()) { cookbook in
                Button {
                    navigationPath.append(cookbook.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(cookbook.icon)
                            .font(.title2)
                            .frame(width: 36, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cookbook.name)
                                    .foregroundStyle(.primary)
                                Text("🔜")
                                    .font(.caption)
                            }

                            let recipeCount = manager.recipes(inCookbook: cookbook.id).count
                            Text(String(localized: "cookbook.recipes.count \(recipeCount)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Cookbook Content (Chapters & Recipes)

    @ViewBuilder
    private var cookbookContent: some View {
        let children = getSortedChildren()

        if children.isEmpty {
            VStack(spacing: 12) {
                Text("📭")
                    .font(.largeTitle)
                Text("cookbook.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowBackground(Color.clear)
        } else {
            ForEach(children, id: \.self) { child in
                switch child {
                case .chapter(let item):
                    chapterRow(item)
                case .recipe(let item, let recipe):
                    recipeRow(item, recipe: recipe)
                }
            }
        }
    }

    // Get sorted children: chapters first, then recipes
    private func getSortedChildren() -> [CookbookChild] {
        guard let cookbookID = currentCookbookID else { return [] }

        let items = manager.recipeChildren(of: currentChapterID, in: cookbookID)
        var result: [CookbookChild] = []

        // Separate chapters and recipes
        var chapters: [(RecipeMenuItem, Int)] = []
        var recipes: [(RecipeMenuItem, PrePromptRecipe, Int)] = []

        for (index, item) in items.enumerated() {
            if item.isChapter {
                chapters.append((item, index))
            } else if let recipeID = item.recipeID,
                      let recipe = manager.recipe(withID: recipeID) {
                recipes.append((item, recipe, index))
            }
        }

        // Chapters first (sorted by sortOrder)
        for (item, _) in chapters.sorted(by: { $0.0.sortOrder < $1.0.sortOrder }) {
            result.append(.chapter(item))
        }

        // Then recipes (sorted by sortOrder)
        for (item, recipe, _) in recipes.sorted(by: { $0.0.sortOrder < $1.0.sortOrder }) {
            result.append(.recipe(item, recipe))
        }

        return result
    }

    private func chapterRow(_ item: RecipeMenuItem) -> some View {
        Button {
            navigationPath.append(item.id)
        } label: {
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 36, alignment: .leading)

                HStack {
                    Text(item.name)
                        .foregroundStyle(.primary)
                    Text("🔜")
                        .font(.caption)
                }

                Spacer()

                // Child count badge
                if let cookbookID = currentCookbookID {
                    let childCount = manager.recipeChildren(of: item.id, in: cookbookID).count
                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func recipeRow(_ item: RecipeMenuItem, recipe: PrePromptRecipe) -> some View {
        Button {
            onSelectRecipe(recipe)
            navigationPath.removeAll()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(item.icon)
                    .font(.title2)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(.primary)

                    // Show element count
                    let elementCount = recipe.elementIDs.count
                    Text(String(localized: "catalog.recipe.elements \(elementCount)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Return indicator - recipe can be selected
                Text("⏎")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }

    private func navigateBack() {
        if !navigationPath.isEmpty {
            navigationPath.removeLast()
        }
    }

    // Helper enum for sorted children
    private enum CookbookChild: Hashable {
        case chapter(RecipeMenuItem)
        case recipe(RecipeMenuItem, PrePromptRecipe)

        func hash(into hasher: inout Hasher) {
            switch self {
            case .chapter(let item):
                hasher.combine("chapter")
                hasher.combine(item.id)
            case .recipe(let item, _):
                hasher.combine("recipe")
                hasher.combine(item.id)
            }
        }

        static func == (lhs: CookbookChild, rhs: CookbookChild) -> Bool {
            switch (lhs, rhs) {
            case (.chapter(let a), .chapter(let b)):
                return a.id == b.id
            case (.recipe(let a, _), .recipe(let b, _)):
                return a.id == b.id
            default:
                return false
            }
        }
    }
}

#Preview {
    ComposeMailView()
}
