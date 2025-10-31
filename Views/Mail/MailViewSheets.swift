// MailViewSheets.swift - Sheet und Popup Management für MailView in AILO_APP
import SwiftUI
import Foundation

// MARK: - Active Sheet Enum

enum MailViewActiveSheet: Identifiable {
    case compose
    case filter(QuickFilter)
    case sorting(MailSortMode)
    case bulkActions([MessageHeaderEntity])
    case accountSettings(AccountEntity)
    
    var id: String {
        switch self {
        case .compose:
            return "compose"
        case .filter(let filter):
            return "filter_\(filter.rawValue)"
        case .sorting(let mode):
            return "sorting_\(mode.rawValue)"
        case .bulkActions(let mails):
            return "bulk_\(mails.count)"
        case .accountSettings(let account):
            return "settings_\(account.id.uuidString)"
        }
    }
}

// MARK: - Quick Filter Enum

enum QuickFilter: String, CaseIterable {
    case all, unread, flagged
    
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all: return "app.mail.filter.all"
        case .unread: return "app.mail.filter.unread"
        case .flagged: return "app.mail.filter.flagged"
        }
    }
    
    var systemImage: String {
        switch self {
        case .all: return "envelope"
        case .unread: return "envelope.badge"
        case .flagged: return "flag"
        }
    }
}

// MARK: - Sheet Content Builder Function

/// Creates sheet content for MailView - used as standalone function to avoid access level issues
@ViewBuilder
func createMailViewSheetContent(
    for sheet: MailViewActiveSheet,
    quickFilter: Binding<QuickFilter>,
    sortMode: Binding<MailSortMode>,
    activeSheet: Binding<MailViewActiveSheet?>,
    onMarkAllRead: @escaping () async -> Void,
    onMarkAllUnread: @escaping () async -> Void,
    onDeleteMail: @escaping (MessageHeaderEntity) async -> Void,
    onToggleFlag: @escaping (MessageHeaderEntity, String) async -> Void,
    onSyncAccount: @escaping (UUID) async -> Void,
    onRefreshMails: @escaping () async -> Void
) -> some View {
    switch sheet {
    case .compose:
        ComposeMailView()
        
    case .filter(let currentFilter):
        MailFilterSheet(
            currentFilter: currentFilter,
            onFilterChanged: { newFilter in
                quickFilter.wrappedValue = newFilter
                activeSheet.wrappedValue = nil
            }
        )
        
    case .sorting(let currentMode):
        MailSortingSheet(
            currentMode: currentMode,
            onSortChanged: { newMode in
                sortMode.wrappedValue = newMode
                activeSheet.wrappedValue = nil
            }
        )
        
    case .bulkActions(let mails):
        MailBulkActionsSheet(
            mails: mails,
            onMarkAllRead: {
                Task { await onMarkAllRead() }
                activeSheet.wrappedValue = nil
            },
            onMarkAllUnread: {
                Task { await onMarkAllUnread() }
                activeSheet.wrappedValue = nil
            },
            onDeleteAll: {
                Task {
                    for mail in mails {
                        await onDeleteMail(mail)
                    }
                }
                activeSheet.wrappedValue = nil
            },
            onFlagAll: {
                Task {
                    for mail in mails {
                        await onToggleFlag(mail, "\\Flagged")
                    }
                }
                activeSheet.wrappedValue = nil
            }
        )
        
    case .accountSettings(let account):
        AccountSettingsSheet(
            account: account,
            onSync: { accountId in
                Task {
                    await onSyncAccount(accountId)
                    await onRefreshMails()
                }
                activeSheet.wrappedValue = nil
            },
            onClose: {
                activeSheet.wrappedValue = nil
            }
        )
    }
}

// MARK: - Mail Filter Sheet

private struct MailFilterSheet: View {
    let currentFilter: QuickFilter
    let onFilterChanged: (QuickFilter) -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("app.mail.filter.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                VStack(spacing: 12) {
                    ForEach(QuickFilter.allCases, id: \.self) { filter in
                        Button(action: { onFilterChanged(filter) }) {
                            HStack {
                                Image(systemName: filter.systemImage)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                
                                Text(filter.localizedTitle)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if filter == currentFilter {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(filter == currentFilter ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("app.mail.filter.sheet_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("app.common.close") {
                        onFilterChanged(currentFilter) // Close without changing
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Mail Sorting Sheet

private struct MailSortingSheet: View {
    let currentMode: MailSortMode
    let onSortChanged: (MailSortMode) -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("app.mail.sort.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                VStack(spacing: 12) {
                    ForEach(MailSortMode.allCases, id: \.self) { mode in
                        Button(action: { onSortChanged(mode) }) {
                            HStack {
                                Image(systemName: mode.systemImage)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                
                                Text(mode.localizedTitle)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if mode == currentMode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(mode == currentMode ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("app.mail.sort.sheet_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("app.common.close") {
                        onSortChanged(currentMode) // Close without changing
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Mail Bulk Actions Sheet

private struct MailBulkActionsSheet: View {
    let mails: [MessageHeaderEntity]
    let onMarkAllRead: () -> Void
    let onMarkAllUnread: () -> Void
    let onDeleteAll: () -> Void
    let onFlagAll: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("app.mail.bulk.title")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top)
                
                Text("app.mail.bulk.subtitle \(mails.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 12) {
                    BulkActionButton(
                        title: "app.mail.mark_all_read",
                        systemImage: "envelope.open",
                        action: onMarkAllRead
                    )
                    
                    BulkActionButton(
                        title: "app.mail.mark_all_unread",
                        systemImage: "envelope.badge",
                        action: onMarkAllUnread
                    )
                    
                    BulkActionButton(
                        title: "app.mail.flag_all",
                        systemImage: "flag",
                        action: onFlagAll
                    )
                    
                    Divider()
                    
                    BulkActionButton(
                        title: "app.mail.delete_all",
                        systemImage: "trash",
                        destructive: true,
                        action: onDeleteAll
                    )
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("app.mail.bulk.sheet_title")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    @ViewBuilder
    private func BulkActionButton(
        title: LocalizedStringKey,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(destructive ? .red : .accentColor)
                    .frame(width: 24)
                
                Text(title)
                    .foregroundColor(destructive ? .red : .primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(destructive ? Color.red.opacity(0.05) : Color.accentColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(destructive ? Color.red.opacity(0.2) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account Settings Sheet

private struct AccountSettingsSheet: View {
    let account: AccountEntity
    let onSync: (UUID) -> Void
    let onClose: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Account Info Header
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    
                    Text(account.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(account.emailAddress)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top)
                
                // Actions
                VStack(spacing: 12) {
                    SettingsActionButton(
                        title: "app.mail.sync_account",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: { onSync(account.id) }
                    )
                    
                    SettingsActionButton(
                        title: "app.mail.account_settings",
                        systemImage: "gear",
                        action: {
                            // TODO: Navigate to account settings
                            onClose()
                        }
                    )
                    
                    SettingsActionButton(
                        title: "app.mail.mailbox_settings",
                        systemImage: "tray.2",
                        action: {
                            // TODO: Navigate to mailbox settings
                            onClose()
                        }
                    )
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .navigationTitle("app.mail.account.sheet_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("app.common.close", action: onClose)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    @ViewBuilder
    private func SettingsActionButton(
        title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(.accentColor)
                    .frame(width: 24)
                
                Text(title)
                    .foregroundColor(.primary)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MailSortMode Extension

extension MailSortMode {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .dateDesc: return "app.mail.sort_newest_first"
        case .sender: return "app.mail.sort_by_sender"
        }
    }
    
    var systemImage: String {
        switch self {
        case .dateDesc: return "arrow.down"
        case .sender: return "person"
        }
    }
}