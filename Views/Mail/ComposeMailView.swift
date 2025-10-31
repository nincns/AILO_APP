// ComposeMailView.swift - Enhanced mail composer for AILO_APP
import SwiftUI
import PhotosUI

struct ComposeMailView: View {
    @Environment(\.dismiss) private var dismiss

    // MARK: - Addressing
    @State private var accounts: [MailAccountConfig] = []
    @State private var activeIDs: Set<UUID> = []
    @State private var selectedAccountId: UUID? = nil

    @State private var to: String = ""
    @State private var cc: String = ""
    @State private var bcc: String = ""
    @State private var subject: String = ""

    // MARK: - Body
    @State private var isHTML: Bool = false
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

    // Autosave debounce
    @State private var autosaveTask: Task<Void, Never>? = nil

    // Prefill subscription (reply/forward)
    @State private var prefillToken: UUID? = nil

    private let autosaveKey = "compose.autosave"

    var body: some View {
        NavigationStack {
            Form {
                // From
                Section(String(localized: "app.mail.compose.from")) {
                    Picker(String(localized: "app.mail.compose.from"), selection: $selectedAccountId) {
                        ForEach(activeAccounts(), id: \.id) { acc in
                            Text(acc.accountName).tag(acc.id as UUID?)
                        }
                    }
                }

                // Recipients
                Section(String(localized: "app.mail.compose.to")) {
                    TextField(String(localized: "app.mail.compose.to_placeholder"), text: $to)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.emailAddress)
                    TextField("CC", text: $cc)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.emailAddress)
                    TextField("BCC", text: $bcc)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.emailAddress)
                }

                // Subject
                Section(String(localized: "app.mail.compose.subject")) {
                    TextField(String(localized: "app.mail.compose.subject_placeholder"), text: $subject)
                        .textInputAutocapitalization(.sentences)
                }

                // Body
                Section(String(localized: "app.mail.compose.body")) {
                    Toggle(String(localized: "app.mail.compose.html"), isOn: $isHTML)
                    if isHTML {
                        TextEditor(text: $htmlBody)
                            .frame(minHeight: 200)
                            .font(.body)
                    } else {
                        TextEditor(text: $textBody)
                            .frame(minHeight: 200)
                            .font(.body)
                    }
                }

                // Attachments
                Section(String(localized: "app.mail.compose.attachments")) {
                    if attachments.isEmpty {
                        Text(String(localized: "app.mail.compose.no_attachments"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(attachments) { att in
                            HStack {
                                Image(systemName: "paperclip")
                                Text(att.filename).lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    attachments.removeAll { $0.id == att.id }
                                } label: { Image(systemName: "trash") }
                            }
                        }
                    }
                    HStack {
                        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                            Label(String(localized: "app.mail.compose.add_photo"), systemImage: "photo")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label(String(localized: "app.mail.compose.add_file"), systemImage: "doc")
                        }
                    }
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
                loadAutosave()
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
        let hasBody = isHTML ? !htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTo && hasSubject && hasBody
    }

    // MARK: - Actions
    private func sendAndDismiss() {
        guard let accId = selectedAccountId, let account = accounts.first(where: { $0.id == accId }) else { return }
        // Build draft model
        let from = MailSendAddress(account.replyTo ?? account.recvUsername)
        let toList = splitEmails(to)
        let ccList = splitEmails(cc)
        let bccList = splitEmails(bcc)
        let draft = MailDraft(
            from: from,
            to: toList,
            cc: ccList,
            bcc: bccList,
            subject: subject,
            textBody: isHTML ? nil : textBody,
            htmlBody: isHTML ? htmlBody : nil
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
        self.isHTML = dict["isHTML"] as? Bool ?? false
        if let idStr = dict["accountId"] as? String, let id = UUID(uuidString: idStr) {
            self.selectedAccountId = id
        }
    }

    private func clearAutosave() { UserDefaults.standard.removeObject(forKey: autosaveKey) }

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

#Preview {
    ComposeMailView()
}
