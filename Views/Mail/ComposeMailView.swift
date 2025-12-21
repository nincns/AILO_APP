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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Compact header section
                VStack(spacing: 0) {
                    // From row with HTML toggle
                    HStack {
                        Text("Von")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Picker("", selection: $selectedAccountId) {
                            ForEach(activeAccounts(), id: \.id) { acc in
                                Text(acc.accountName).tag(acc.id as UUID?)
                            }
                        }
                        .labelsHidden()

                        Spacer()

                        // HTML Toggle
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
        let fromEmail = account.recvUsername
        let fromName = account.displayName ?? account.accountName
        let from = MailSendAddress(fromEmail, name: fromName)

        // Reply-To from account settings (only if different from From)
        let replyToAddr: MailSendAddress?
        if let replyToEmail = account.replyTo, !replyToEmail.isEmpty, replyToEmail != fromEmail {
            replyToAddr = MailSendAddress(replyToEmail, name: fromName)
        } else {
            replyToAddr = nil
        }

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

        let draft = MailDraft(
            from: from,
            replyTo: replyToAddr,
            to: toList,
            cc: ccList,
            bcc: bccList,
            subject: subject,
            textBody: isHTML ? nil : textBody,
            htmlBody: cleanedHtmlBody
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

        // Build recipients - bei Forward leer lassen
        if isForward {
            // Forward: Empfänger leer, Benutzer füllt aus
            self.to = ""
            self.cc = ""
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
            return account.recvUsername
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

#Preview {
    ComposeMailView()
}
