//AILO_APP/Configuration/MailManager.swift
// AILO_APP/Configuration/MailManager.swift
import SwiftUI
import Combine
import Foundation

fileprivate enum MailStorageManager {
    static let key = "mail.accounts"
    static func load() -> [MailAccountConfig] {
        if let data = UserDefaults.standard.data(forKey: key) {
            return (try? JSONDecoder().decode([MailAccountConfig].self, from: data)) ?? []
        }
        return []
    }
    static func save(_ accounts: [MailAccountConfig]) {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

fileprivate enum MailActiveStore {
    static let key = "mail.accounts.active"
    static func load() -> Set<UUID> {
        if let data = UserDefaults.standard.data(forKey: key),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            return Set(ids)
        }
        return []
    }
    static func save(_ set: Set<UUID>) {
        let arr = Array(set)
        if let data = try? JSONEncoder().encode(arr) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private struct MailRow: View {
    let item: MailAccountConfig
    let isActive: Bool
    let onToggle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(isActive ? .accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(PlainButtonStyle())

            Text(item.accountName)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .padding(.vertical, 6)
                .padding(.leading, 4)
        }
        .padding(.vertical, 4)
    }
}

struct MailManager: View {
    @State private var accounts: [MailAccountConfig] = MailStorageManager.load()
    @State private var activeIDs: Set<UUID> = MailActiveStore.load()

    @State private var pushAddEditor: Bool = false
    @State private var showAddEditor: Bool = false
    @State private var cancellables: Set<AnyCancellable> = []

    var body: some View {
        List {
            Section(header: Text("config.section.mailAccounts")) {
                ForEach(accounts, id: \.id) { (item: MailAccountConfig) in
                    HStack(spacing: 12) {
                        NavigationLink(destination: MailEditor(existing: item)) {
                            Text(item.accountName)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .padding(.vertical, 6)
                                .padding(.leading, 4)
                        }
                        Spacer(minLength: 12)
                        Button(action: { toggleActive(for: item.id) }) {
                            Image(systemName: activeIDs.contains(item.id) ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(activeIDs.contains(item.id) ? .accentColor : .secondary)
                                .imageScale(.large)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .onDelete(perform: delete)
                .onMove(perform: move)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mailAccountsDidChange)) { _ in
            accounts = MailStorageManager.load()
            // Lade den aktuellen activeIDs Status neu - NICHT automatisch neue hinzufügen!
            activeIDs = MailActiveStore.load()
            startSyncForActiveAccounts()
        }
        .onAppear {
            startSyncForActiveAccounts()
        }
        .navigationTitle(Text("config.nav.mailManager"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddEditor = true }) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("config.mail.add"))
            }
        }
        .sheet(isPresented: $showAddEditor, onDismiss: {
            let oldAccountIds = Set(accounts.map { $0.id })
            accounts = MailStorageManager.load()
            let newAccountIds = Set(accounts.map { $0.id })

            // Nur WIRKLICH neue Konten (die vorher nicht existierten) automatisch aktivieren
            let trulyNewAccounts = newAccountIds.subtracting(oldAccountIds)
            if !trulyNewAccounts.isEmpty {
                activeIDs.formUnion(trulyNewAccounts)
                MailActiveStore.save(activeIDs)
            }
            startSyncForActiveAccounts()
        }) {
            NavigationStack { MailEditor() }
        }
    }

    private func toggleActive(for id: UUID) {
        if activeIDs.contains(id) { activeIDs.remove(id) } else { activeIDs.insert(id) }
        MailActiveStore.save(activeIDs)
        startSyncForActiveAccounts()

        // Notify MailView to reload with updated active accounts
        NotificationCenter.default.post(name: .mailActiveStatusDidChange, object: nil)
    }

    private func delete(at offsets: IndexSet) {
        let removedIDs = offsets.map { accounts[$0].id }
        accounts.remove(atOffsets: offsets)
        MailStorageManager.save(accounts)
        activeIDs.subtract(removedIDs)
        MailActiveStore.save(activeIDs)
        startSyncForActiveAccounts()
    }

    private func move(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        MailStorageManager.save(accounts)
    }

    private func startSyncForActiveAccounts() {
        // Start background sync only for active accounts; stop for inactive ones.
        let repo = MailRepository.shared
        let activeSet = activeIDs
        let allIds = Set(accounts.map { $0.id })

        for id in allIds {
            if activeSet.contains(id) {
                repo.startBackgroundSync(accountId: id)
            } else {
                repo.stopBackgroundSync(accountId: id)
            }
        }
    }
}
