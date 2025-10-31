// RegularSplitView.swift - Minimal placeholder implementation to satisfy MailView dependencies
import SwiftUI
import WebKit

struct RegularSplitView: View {
    let mails: [MessageHeaderEntity]
    @Binding var selectedMailUID: String?
    @Binding var searchText: String
    let onDelete: (MessageHeaderEntity) -> Void
    let onToggleFlag: (MessageHeaderEntity) -> Void
    let onToggleRead: (MessageHeaderEntity) -> Void
    let onRefresh: () async -> Void

    @State private var isLoadingBody: Bool = false
    @State private var bodyText: String = ""
    @State private var isHTML: Bool = false
    @State private var attachments: [AttachmentEntity] = []
    @State private var tempFiles: [URL] = []

    private func currentMessage() -> MessageHeaderEntity? {
        guard let uid = selectedMailUID else { return nil }
        return mails.first(where: { $0.uid == uid })
    }

    private func fetchSelectedBody() {
        guard let msg = currentMessage() else { return }
        isLoadingBody = true
        bodyText = ""
        attachments = []
        tempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles = []
        Task {
            do {
                // 🚀 SOFORT: Load cached mail body from local storage first
                print("📱 Loading cached mail body immediately...")
                if let cachedText = try MailRepository.shared.loadCachedBody(accountId: msg.accountId, folder: msg.folder, uid: msg.uid) {
                    await MainActor.run {
                        bodyText = cachedText
                        let lower = cachedText.lowercased()
                        isHTML = lower.contains("<html") || lower.contains("<body") || lower.contains("<div")
                        isLoadingBody = false
                    }
                    print("✅ Cached mail body loaded instantly")
                } else {
                    // 🔄 FALLBACK: If no cached body, try regular loading
                    print("📧 No cached body found, loading from repository...")
                    if let text = try MailRepository.shared.getBody(accountId: msg.accountId, folder: msg.folder, uid: msg.uid) {
                        await MainActor.run {
                            bodyText = text
                            let lower = text.lowercased()
                            isHTML = lower.contains("<html") || lower.contains("<body") || lower.contains("<div")
                        }
                    } else {
                        await MainActor.run { bodyText = String(localized: "app.mail.body_placeholder"); isHTML = false }
                    }
                    
                    await MainActor.run { isLoadingBody = false }
                }
                
                // Load attachments in parallel if available
                if let dao = MailRepository.shared.dao {
                    if let anyList = try? dao.attachments(accountId: msg.accountId, folder: msg.folder, uid: msg.uid) as? [AttachmentEntity] {
                        await MainActor.run { attachments = anyList }
                        // Write temp files for ShareLink
                        var urls: [URL] = []
                        for a in anyList {
                            if let data = a.data {
                                let url = FileManager.default.temporaryDirectory.appendingPathComponent(a.filename.isEmpty ? a.partId + ".dat" : a.filename)
                                try? data.write(to: url, options: [.atomic])
                                urls.append(url)
                            }
                        }
                        await MainActor.run { tempFiles = urls }
                    }
                }
            } catch {
                await MainActor.run {
                    bodyText = error.localizedDescription
                    isHTML = false
                    isLoadingBody = false
                }
            }
        }
    }

    private func moveSelection(step: Int) {
        guard let idx = mails.firstIndex(where: { $0.uid == selectedMailUID }) else {
            selectedMailUID = mails.first?.uid
            fetchSelectedBody()
            return
        }
        let newIdx = max(0, min(mails.count - 1, idx + step))
        selectedMailUID = mails[newIdx].uid
        fetchSelectedBody()
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(minWidth: 320)
            Divider()
            detailPane
        }
        .onChange(of: selectedMailUID) { _, _ in fetchSelectedBody() }
        .onAppear { if selectedMailUID == nil { selectedMailUID = mails.first?.uid }; fetchSelectedBody() }
    }

    private var filtered: [MessageHeaderEntity] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return mails }
        return mails.filter { h in
            h.subject.localizedCaseInsensitiveContains(q) || h.from.localizedCaseInsensitiveContains(q)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            // Lightweight search field (binds to parent searchText)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "app.mail.search"), text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemBackground))

            List(selection: $selectedMailUID) {
                ForEach(filtered, id: \.uid) { mail in
                    Button {
                        selectedMailUID = mail.uid
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                if !mail.flags.contains("\\Seen") {
                                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                }
                                Text(mail.from).font(.subheadline).lineLimit(1)
                                if mail.flags.contains("\\Flagged") {
                                    Image(systemName: "flag.fill").foregroundStyle(.orange)
                                }
                                Spacer()
                                if let d = mail.date {
                                    Text(d, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(mail.subject.isEmpty ? String(localized: "app.mail.no_subject") : mail.subject)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fontWeight(mail.flags.contains("\\Seen") ? .regular : .semibold)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { onDelete(mail) } label: { Label("app.common.delete", systemImage: "trash") }
                        Button { onToggleFlag(mail) } label: { Label("app.mail.flag", systemImage: "flag") }
                        Button { onToggleRead(mail) } label: { Label("app.mail.read_unread", systemImage: "envelope") }
                    }
                }
            }
            .refreshable { await onRefresh() }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let current = currentMessage() {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(current.subject.isEmpty ? String(localized: "app.mail.no_subject") : current.subject)
                        .font(.headline)
                    Spacer()
                    if let d = current.date { Text(d.formatted()).font(.caption).foregroundStyle(.secondary) }
                }
                Text(String(localized: "app.mail.from_prefix") + " " + current.from)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                if isLoadingBody {
                    HStack(spacing: 8) { ProgressView(); Text(String(localized: "app.common.loading")).font(.caption).foregroundStyle(.secondary) }
                } else if isHTML {
                    HTMLWebView(html: bodyText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { Text(bodyText).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8) }
                }
                if !attachments.isEmpty || !tempFiles.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "app.mail.attachments")).font(.subheadline)
                        ForEach(Array(attachments.enumerated()), id: \.offset) { idx, att in
                            HStack {
                                Image(systemName: "paperclip").foregroundStyle(.secondary)
                                Text(att.filename.isEmpty ? att.partId : att.filename)
                                    .font(.footnote)
                                Spacer()
                                if idx < tempFiles.count {
                                    ShareLink(item: tempFiles[idx]) { Image(systemName: "square.and.arrow.up") }
                                }
                            }
                        }
                    }
                }
                // Hidden controls with keyboard shortcuts for navigation
                HStack { EmptyView() }
                    .overlay(
                        HStack(spacing: 0) {
                            Button(action: { moveSelection(step: -1) }) { EmptyView() }.keyboardShortcut("k")
                            Button(action: { moveSelection(step: 1) }) { EmptyView() }.keyboardShortcut("j")
                        }
                    )
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView {
                Label("app.mail.no_message_selected", systemImage: "envelope")
            } description: {
                Text("app.mail.no_message_selected_description")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    // Minimal preview with dummy data
    let mails: [MessageHeaderEntity] = [
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "1", from: "alice@example.com", subject: "Hello Alice", date: Date(), flags: []),
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "2", from: "bob@example.com", subject: "Meeting", date: Date().addingTimeInterval(-3600), flags: ["\\Seen"])
    ]
    return RegularSplitView(mails: mails, selectedMailUID: .constant(nil), searchText: .constant(""), onDelete: { _ in }, onToggleFlag: { _ in }, onToggleRead: { _ in }, onRefresh: {})
}

struct HTMLWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(html, baseURL: nil)
    }
}
