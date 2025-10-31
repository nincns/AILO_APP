// CompactMessageListView.swift - Clean list view for mail messages with navigation to detail view
import SwiftUI

struct CompactMessageListView: View {
    let mails: [MessageHeaderEntity]
    let onDelete: (MessageHeaderEntity) -> Void
    let onToggleFlag: (MessageHeaderEntity) -> Void
    let onToggleRead: (MessageHeaderEntity) -> Void
    @Binding var searchText: String
    let onRefresh: () async -> Void
    
    init(mails: [MessageHeaderEntity], 
         onDelete: @escaping (MessageHeaderEntity) -> Void,
         onToggleFlag: @escaping (MessageHeaderEntity) -> Void, 
         onToggleRead: @escaping (MessageHeaderEntity) -> Void,
         searchText: Binding<String>,
         onRefresh: @escaping () async -> Void) {
        self.mails = mails
        self.onDelete = onDelete
        self.onToggleFlag = onToggleFlag
        self.onToggleRead = onToggleRead
        self._searchText = searchText
        self.onRefresh = onRefresh
    }

    var body: some View {
        List {
            if #available(iOS 17.0, *) {
                Section {
                    searchField
                }
            } else {
                searchField
            }
            ForEach(filtered, id: \.uid) { mail in
                NavigationLink(value: mail.uid) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            // Unread indicator
                            if !mail.flags.contains("\\Seen") {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                            Text(mail.from)
                                .font(.subheadline)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            if mail.flags.contains("\\Flagged") {
                                Image(systemName: "flag.fill").foregroundStyle(.orange)
                            }
                            Spacer()
                            if let d = mail.date {
                                Text(d, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(mail.subject.isEmpty ? String(localized: "app.mail.no_subject") : mail.subject)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fontWeight(mail.flags.contains("\\Seen") ? .regular : .semibold)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { onDelete(mail) } label: { Label("app.common.delete", systemImage: "trash") }
                    Button { onToggleFlag(mail) } label: { Label("app.mail.flag", systemImage: "flag") }
                    Button { onToggleRead(mail) } label: { Label("app.mail.read_unread", systemImage: "envelope") }
                }
            }
        }
        .refreshable { await onRefresh() }
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

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "app.mail.search"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }
}



#Preview {
    let mails: [MessageHeaderEntity] = [
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "1", from: "alice@example.com", subject: "Hello Alice", date: Date(), flags: []),
        MessageHeaderEntity(accountId: UUID(), folder: "INBOX", uid: "2", from: "bob@example.com", subject: "Meeting", date: Date().addingTimeInterval(-3600), flags: ["\\Seen"]) 
    ]
    return NavigationStack {
        CompactMessageListView(mails: mails, onDelete: { _ in }, onToggleFlag: { _ in }, onToggleRead: { _ in }, searchText: .constant(""), onRefresh: {})
    }
}
