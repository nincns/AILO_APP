// CompactMessageListView.swift - Clean list view for mail messages with navigation to detail view
import SwiftUI

struct CompactMessageListView: View {
    let mails: [MessageHeaderEntity]
    let onDelete: (MessageHeaderEntity) -> Void
    let onToggleFlag: (MessageHeaderEntity) -> Void
    let onToggleRead: (MessageHeaderEntity) -> Void
    @Binding var searchText: String
    let onRefresh: () async -> Void
    @EnvironmentObject var mailManager: MailViewModel

    /// Viewport-based sync manager for on-demand synchronization
    @ObservedObject var viewportManager: ViewportSyncManager

    init(mails: [MessageHeaderEntity],
         onDelete: @escaping (MessageHeaderEntity) -> Void,
         onToggleFlag: @escaping (MessageHeaderEntity) -> Void,
         onToggleRead: @escaping (MessageHeaderEntity) -> Void,
         searchText: Binding<String>,
         onRefresh: @escaping () async -> Void,
         viewportManager: ViewportSyncManager = ViewportSyncManager()) {
        self.mails = mails
        self.onDelete = onDelete
        self.onToggleFlag = onToggleFlag
        self.onToggleRead = onToggleRead
        self._searchText = searchText
        self.onRefresh = onRefresh
        self.viewportManager = viewportManager
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.uid) { mail in
                NavigationLink(value: mail.uid) {
                    EnhancedMailRowView(
                        mail: mail,
                        hasAttachments: mailManager.attachmentStatus[mail.uid] ?? false
                    )
                }
                // MARK: - Viewport Tracking für Scope-basierte Synchronisation
                .onAppear {
                    viewportManager.rowAppeared(uid: mail.uid)
                }
                .onDisappear {
                    viewportManager.rowDisappeared(uid: mail.uid)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { onDelete(mail) } label: { Label("app.common.delete", systemImage: "trash") }
                    Button { onToggleFlag(mail) } label: { Label("app.mail.flag", systemImage: "flag") }
                    Button { onToggleRead(mail) } label: { Label("app.mail.read_unread", systemImage: "envelope") }
                }
            }
        }
        .refreshable { await onRefresh() }
        .onAppear {
            // Aktualisiere die Liste bekannter UIDs für Prefetch-Berechnung
            viewportManager.updateKnownUIDs(filtered.map { $0.uid })
        }
        .onChange(of: filtered) { _, newFiltered in
            // Aktualisiere bei Filteränderungen
            viewportManager.updateKnownUIDs(newFiltered.map { $0.uid })
        }
        .navigationDestination(for: String.self) { uid in
            if let mail = mails.first(where: { $0.uid == uid }) {
                MessageDetailView(
                    mail: mail,
                    onDelete: onDelete,
                    onToggleFlag: onToggleFlag,
                    onToggleRead: onToggleRead
                )
            } else {
                ContentUnavailableView {
                    Label("app.mail.no_messages", systemImage: "envelope")
                }
            }
        }
    }
    
    private var filtered: [MessageHeaderEntity] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return mails }
        return mails.filter { h in
            h.subject.localizedCaseInsensitiveContains(q) || h.from.localizedCaseInsensitiveContains(q)
        }
    }
}



#Preview {
    let mails: [MessageHeaderEntity] = [
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "1", from: "Montgomery Scott <scotty@beam-me-up.net>", subject: "Anfrage Beta Test", date: Date(), flags: []),
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "2", from: "bob@example.com", subject: "Meeting", date: Date().addingTimeInterval(-3600), flags: ["\\Seen"])
    ]
    return NavigationStack {
        CompactMessageListView(
            mails: mails,
            onDelete: { _ in },
            onToggleFlag: { _ in },
            onToggleRead: { _ in },
            searchText: .constant(""),
            onRefresh: {},
            viewportManager: ViewportSyncManager()
        )
        .environmentObject(MailViewModel())
    }
}

// MARK: - Enhanced Mail Row View

struct EnhancedMailRowView: View {
    let mail: MessageHeaderEntity
    let hasAttachments: Bool  // NEU
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Zeile 1: Status + Sender Name + Datum  
            HStack(alignment: .firstTextBaseline) {
                // Unread indicator + Status flags
                HStack(spacing: 4) {
                    if !mail.flags.contains("\\Seen") {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    } else {
                        // Spacer für gleiche Einrückung
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 8, height: 8)
                    }

                    if mail.flags.contains("\\Flagged") {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }

                    // S/MIME Signature Status Icon
                    if let sigStatus = mail.signatureStatus {
                        Image(systemName: sigStatus.iconName)
                            .foregroundStyle(signatureColor(for: sigStatus))
                            .font(.caption)
                    }
                }
                
                // Sender Name (extract display name if available)
                Text(extractSenderName(from: mail.from))
                    .font(.subheadline)
                    .fontWeight(mail.flags.contains("\\Seen") ? .medium : .semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Datum
                if let date = mail.date {
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Zeile 2: E-Mail-Adresse (falls verfügbar und anders als Display Name)
            if let emailAddress = extractEmailAddress(from: mail.from),
               emailAddress != extractSenderName(from: mail.from) {
                HStack {
                    Spacer()
                        .frame(width: 12) // Einrückung für Alignment
                    
                    Text(emailAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                }
            }
            
            // Zeile 3: Attachment-Icon + Betreff (linksbündig)
            HStack(alignment: .center, spacing: 6) {
                Spacer()
                    .frame(width: 12)
                
                if hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(mail.subject.isEmpty ? String(localized: "app.mail.no_subject") : mail.subject)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Helper Methods
    
    /// Extrahiert den Display-Namen aus "Montgomery Scott <scotty@example.com>" oder gibt die gesamte Adresse zurück
    private func extractSenderName(from fromString: String) -> String {
        let trimmed = fromString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for "Display Name <email@domain.com>" format
        if let angleIndex = trimmed.firstIndex(of: "<") {
            let displayName = String(trimmed[..<angleIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !displayName.isEmpty {
                // Remove quotes if present
                let cleaned = displayName.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return cleaned.isEmpty ? trimmed : cleaned
            }
        }
        
        // Fallback: return the entire string
        return trimmed
    }
    
    /// Extrahiert nur die E-Mail-Adresse aus "Montgomery Scott <scotty@example.com>"
    private func extractEmailAddress(from fromString: String) -> String? {
        let trimmed = fromString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for "Display Name <email@domain.com>" format
        if let startIndex = trimmed.firstIndex(of: "<"),
           let endIndex = trimmed.firstIndex(of: ">") {
            let email = String(trimmed[trimmed.index(after: startIndex)..<endIndex])
            return email.isEmpty ? nil : email
        }

        // If it's just an email address, return it only if it contains @
        if trimmed.contains("@") && !trimmed.contains(" ") {
            return trimmed
        }

        return nil
    }

    /// Returns the color for the S/MIME signature status icon
    private func signatureColor(for status: SignatureStatus) -> Color {
        switch status {
        case .valid: return .green
        case .validUntrusted, .validExpired: return .orange
        case .invalid, .error: return .red
        case .notSigned: return .secondary
        }
    }
}
