// AILO_APP/Features/Schreiben/SchreibenMailView.swift

import SwiftUI
import Foundation

// A tiny broadcast center so the editor view can register a closure for compose-prefill
final class ComposePrefillCenter {
    static let shared = ComposePrefillCenter()
    private let lock = NSLock()
    private var handlers: [UUID: (String) -> Void] = [:]
    @discardableResult
    func register(handler: @escaping (String) -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        handlers[id] = handler
        return id
    }
    func unregister(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        handlers[id] = nil
    }
    func broadcast(_ text: String) {
        lock.lock(); let callbacks = Array(handlers.values); lock.unlock()
        for cb in callbacks { cb(text) }
    }
}

struct SchreibenMailView: View {
    @Environment(\.dismiss) private var dismiss
    private let composePrefillKey = "compose.prefill"
    private let composePrefillNotification = Notification.Name("compose.prefill")
    // Optional direkter Rückkanal zur SchreibenView (vermeidet Timing-Probleme)
    let onPick: (String) -> Void
    // Optionaler Dismiss-Callback des Parents (setzt z.B. showMailImport = false)
    var onDismissRequest: (() -> Void)? = nil
    // MARK: - State
    @State private var accounts: [MailAccountConfig] = []
    @State private var activeIDs: Set<UUID> = []
    @State private var selectedAccountId: UUID? = nil
    @State private var folders: [String] = []
    @State private var selectedFolder: String = "INBOX"

    @State private var messages: [MailSendReceive.MailHeader] = []
    @State private var selectedUID: String? = nil
    @State private var isLoading: Bool = false
    @State private var loadError: String? = nil
    @State private var showCopiedAlert: Bool = false

    // Preview state
    @State private var previewHTML: String? = nil
    @State private var previewText: String? = nil
    @State private var isLoadingPreview: Bool = false

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Account picker
            HStack {
                Text(LocalizedStringKey("mail.inbox.account"))
                Spacer()
                Picker(LocalizedStringKey("mail.inbox.account"), selection: $selectedAccountId) {
                    ForEach(accounts, id: \.id) { acc in
                        Text(acc.accountName).tag(acc.id as UUID?)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedAccountId) { _, _ in
                    Task {
                        await fetchFolders()
                        await fetchInbox()
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Folder picker (if available)
            if !folders.isEmpty {
                HStack {
                    Text(LocalizedStringKey("mail.inbox.folder"))
                    Spacer()
                    Picker(LocalizedStringKey("mail.inbox.folder"), selection: $selectedFolder) {
                        ForEach(folders, id: \.self) { name in
                            Text(localizedFolderName(name)).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedFolder) { _, _ in
                        Task { await fetchInbox() }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Message list / states
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(LocalizedStringKey("mail.inbox.loading"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if let err = loadError {
                    VStack(spacing: 8) {
                        Text(verbatim: err)
                            .multilineTextAlignment(.center)
                        Button(LocalizedStringKey("mail.inbox.retry")) {
                            Task { await fetchInbox() }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if messages.isEmpty {
                    Text(LocalizedStringKey("mail.inbox.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else {
                    VStack(spacing: 0) {
                        // Mail list (top half)
                        List {
                            ForEach(Array(messages), id: \.id) { msg in
                                HStack(alignment: .top, spacing: 10) {
                                    // Radio Button
                                    Button(action: {
                                        selectedUID = msg.id
                                        Task { await loadPreview(for: msg) }
                                    }) {
                                        Image(systemName: (selectedUID == msg.id) ? "largecircle.fill.circle" : "circle")
                                            .imageScale(.large)
                                    }
                                    .buttonStyle(.plain)

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(verbatim: msg.subject)
                                                .font(.headline)
                                                .lineLimit(2)
                                            if msg.unread { Circle().frame(width: 6, height: 6) }
                                        }
                                        Text(dateString(msg.date))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        if !msg.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(verbatim: msg.from)
                                                .font(.body)
                                                .lineLimit(1)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedUID = msg.id
                                    Task { await loadPreview(for: msg) }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .disabled(isLoading)
                        .frame(maxHeight: selectedUID != nil ? 200 : .infinity)

                        // Preview section (when mail selected)
                        if selectedUID != nil {
                            Divider()
                            VStack(spacing: 8) {
                                HStack {
                                    Text(String(localized: "mail.import.preview"))
                                        .font(.headline)
                                    Spacer()
                                    if isLoadingPreview {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.top, 8)

                                if let html = previewHTML {
                                    MailPreviewWebView(html: html)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else if let text = previewText {
                                    ScrollView {
                                        Text(text)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal)
                                    }
                                } else if !isLoadingPreview {
                                    Text(String(localized: "mail.import.preview.empty"))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }

                        // Import Button
                        HStack {
                            Spacer()
                            Button {
                                Task { await importSelected() }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text(String(localized: "mail.inbox.import"))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading || selectedUID == nil)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .navigationTitle(Text(localizedFolderName(selectedFolder)))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await fetchInbox(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(LocalizedStringKey("mail.inbox.refresh"))
                .disabled(selectedAccountId == nil)
            }
        }
        .onAppear {
            loadAccounts()
            Task { await fetchFolders() }
        }
        .alert(Text("Text kopiert"), isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Der E‑Mail‑Text wurde zusätzlich in die Zwischenablage gelegt. Falls der automatische Import nicht greift, kannst du ihn direkt einfügen.")
        }
    }

    private func importSelected() async {
        guard let uid = selectedUID, let msg = messages.first(where: { $0.id == uid }) else { return }
        await fetchAndSendToComposer(for: msg)
        // kurze Verzögerung, dann Sheet schließen
        try? await Task.sleep(nanoseconds: 80_000_000)
        await MainActor.run {
            // Erst den Parent schließen lassen (setzt z.B. showMailImport = false), dann eigenes dismiss() als Fallback
            onDismissRequest?()
            dismiss()
        }
    }

    // MARK: - Helpers
    private func localizedFolderName(_ raw: String) -> String {
        let l = raw.lowercased()
        if l == "inbox" || l.contains("inbox") { return String(localized: "mail.folder.inbox") }
        if l.contains("sent") { return String(localized: "mail.folder.sent") }
        if l.contains("draft") { return String(localized: "mail.folder.drafts") }
        if l.contains("trash") || l.contains("deleted") { return String(localized: "mail.folder.trash") }
        if l.contains("spam") || l.contains("junk") { return String(localized: "mail.folder.spam") }
        return raw
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return withoutTags
    }

    @MainActor
    private func sendToComposer(_ text: String) {
        UserDefaults.standard.set(text, forKey: composePrefillKey)
        NotificationCenter.default.post(name: composePrefillNotification, object: nil)
        // Also broadcast via the in-process center, so listeners can set any editor field name.
        ComposePrefillCenter.shared.broadcast(text)
    }

    private func fetchAndSendToComposer(for msg: MailSendReceive.MailHeader) async {
        guard let account = selectedAccount() else { return }
        let service = MailSendReceive()
        let folder = selectedFolder
        let res = await service.fetchMessageUID(msg.id, folder: folder, using: account)
        switch res {
        case .success(let full):
            // 1) Bevorzugt Text-Teil, sonst HTML zu Text strippen
            var raw = full.textBody ?? (full.htmlBody.map { stripHTML($0) } ?? "")
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Minimaler Fallback mit Headern, falls wirklich kein Body vorhanden ist
                let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
                let hdr = full.header
                raw = [
                    "From: \(hdr.from)",
                    "Subject: \(hdr.subject)",
                    "Date: \(df.string(from: hdr.date))",
                    "",
                    "(Kein Textkörper gefunden)"
                ].joined(separator: "\n")
            }
            let cleaned = raw.replacingOccurrences(of: "\r", with: "\n")
            // Debug: Länge des zu übergebenden Textes loggen
            print("[ComposePrefill] len=\(cleaned.count) from uid=\(msg.id) in folder=\(folder)")
            // 2) Direkt an Parent geben und zusätzlich via UserDefaults/Notification posten
            await MainActor.run {
                onPick(cleaned)
                sendToComposer(cleaned)
            }
            await MainActor.run {
                #if canImport(UIKit)
                UIPasteboard.general.string = cleaned
                #endif
                showCopiedAlert = true
            }
        case .failure:
            break
        }
    }

    private func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: "mail.accounts"),
           let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data) {
            self.accounts = list
        } else {
            self.accounts = []
        }
        if let data = UserDefaults.standard.data(forKey: "mail.accounts.active"),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            self.activeIDs = Set(ids)
        } else {
            self.activeIDs = Set(accounts.map { $0.id })
        }
        if selectedAccountId == nil {
            let firstActive = accounts.first { activeIDs.contains($0.id) } ?? accounts.first
            selectedAccountId = firstActive?.id
        }
        Task { await fetchInbox() }
    }

    private func selectedAccount() -> MailAccountConfig? {
        guard let id = selectedAccountId else { return nil }
        return accounts.first(where: { $0.id == id })
    }

    // MARK: - Networking
    private func fetchFolders() async {
        guard let account = selectedAccount() else { return }
        guard account.recvProtocol == .imap else {
            await MainActor.run {
                self.folders = ["INBOX"]
                self.selectedFolder = "INBOX"
            }
            return
        }
        let service = MailSendReceive()
        let res = await service.discoverSystemFolders(using: account)
        switch res {
        case .success(let map):
            var list: [String] = []
            list.append(map.inbox)
            [map.sent, map.drafts, map.trash, map.spam].forEach { n in if !n.isEmpty { list.append(n) } }
            let unique = Array(Set(list)).sorted { $0.lowercased() < $1.lowercased() }
            await MainActor.run {
                self.folders = unique
                if !unique.contains(self.selectedFolder) { self.selectedFolder = map.inbox }
            }
        case .failure:
            await MainActor.run {
                self.folders = ["INBOX"]
                self.selectedFolder = "INBOX"
            }
        }
    }

    private func fetchInbox(force: Bool = false) async {
        guard let account = selectedAccount() else { return }
        if force {
            // Cache leeren, damit beim Refresh wirklich neu geladen wird
            let svc = MailSendReceive()
            svc.clearCache(for: account, folder: selectedFolder)
        }
        isLoading = true
        loadError = nil
        let service = MailSendReceive()
        let res = await service.fetchHeaders(limit: 50, folder: selectedFolder, using: account, preferCache: true, force: force)
        switch res {
        case .success(let headers):
            await MainActor.run {
                self.messages = headers
                self.isLoading = false
            }
        case .failure(let err):
            await MainActor.run {
                self.messages = []
                self.isLoading = false
                self.loadError = err.localizedDescription
            }
        }
    }

    private func loadPreview(for msg: MailSendReceive.MailHeader) async {
        guard let account = selectedAccount() else { return }
        await MainActor.run {
            isLoadingPreview = true
            previewHTML = nil
            previewText = nil
        }
        let service = MailSendReceive()
        let res = await service.fetchMessageUID(msg.id, folder: selectedFolder, using: account)
        switch res {
        case .success(let full):
            await MainActor.run {
                // Prefer HTML for rendered preview
                if let html = full.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    previewHTML = html
                    previewText = nil
                } else if let text = full.textBody, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    previewHTML = nil
                    previewText = text
                } else {
                    previewHTML = nil
                    previewText = String(localized: "mail.import.preview.nobody")
                }
                isLoadingPreview = false
            }
        case .failure:
            await MainActor.run {
                previewHTML = nil
                previewText = String(localized: "mail.import.preview.error")
                isLoadingPreview = false
            }
        }
    }
}

// MARK: - Mail Preview WebView
import WebKit

struct MailPreviewWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
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
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 14px;
                line-height: 1.4;
                margin: 12px;
                padding: 0;
                word-wrap: break-word;
            }
            img { max-width: 100%; height: auto; }
            pre, code { white-space: pre-wrap; word-wrap: break-word; }
            @media (prefers-color-scheme: dark) {
                body { background-color: #1c1c1e; color: #ffffff; }
                a { color: #0a84ff; }
            }
            @media (prefers-color-scheme: light) {
                body { background-color: #ffffff; color: #000000; }
                a { color: #007aff; }
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
    NavigationStack {
        SchreibenMailView(onPick: { text in
            print("[Preview] imported text length=\(text.count)")
        }, onDismissRequest: { })
    }
}
