// MailViewComponents.swift - Supporting Views für MailView in AILO_APP
import SwiftUI
import Foundation

// MARK: - Account Header View

struct AccountHeaderView: View {
    let account: AccountEntity
    let accountId: UUID
    let sortMode: MailSortMode
    let onSync: (UUID) -> Void
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onSortByDateDesc: () -> Void
    let onSortBySender: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(account.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                // Synchronize current account
                Button(action: { onSync(accountId) }) {
                    Label("app.mail.sync", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                // Bulk mark
                Button(action: { onMarkAllRead() }) {
                    Label("app.mail.mark_all_read", systemImage: "envelope.open")
                }
                Button(action: { onMarkAllUnread() }) {
                    Label("app.mail.mark_all_unread", systemImage: "envelope")
                }
                Divider()
                // Sorting options
                Button(action: { onSortByDateDesc() }) {
                    HStack {
                        Label("app.mail.sort_newest_first", systemImage: "arrow.down")
                        if sortMode == .dateDesc { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { onSortBySender() }) {
                    HStack {
                        Label("app.mail.sort_by_sender", systemImage: "person")
                        if sortMode == .sender { Image(systemName: "checkmark") }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }
}

// MARK: - Account Row View

struct AccountRowView: View {
    let account: AccountEntity
    let isSelected: Bool
    let isSyncing: Bool
    let onTap: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle.fill")
                .foregroundColor(isSelected ? .accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(account.displayName)
                    .font(.footnote)
                Text(account.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Mailbox Row Button

struct MailboxRowButton: View {
    let box: MailboxType
    let isSelected: Bool
    let badgeCount: Int?
    let onSelect: () -> Void

    var body: some View {
        buttonContent
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    }
    
    @ViewBuilder
    private var buttonContent: some View {
        if let count = badgeCount {
            Button(action: onSelect) {
                Label(title, systemImage: icon)
            }
            .badge(count)
        } else {
            Button(action: onSelect) {
                Label(title, systemImage: icon)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch box {
        case .inbox: return "app.mail.inbox"
        case .outbox: return "app.mail.outbox"
        case .sent: return "app.mail.sent"
        case .drafts: return "app.mail.drafts"
        case .trash: return "app.mail.trash"
        case .spam: return "app.mail.spam"
        }
    }

    private var icon: String {
        switch box {
        case .inbox: return "tray"
        case .outbox: return "paperplane"
        case .sent: return "paperplane.fill"
        case .drafts: return "doc.text"
        case .trash: return "trash"
        case .spam: return "exclamationmark.octagon"
        }
    }
}