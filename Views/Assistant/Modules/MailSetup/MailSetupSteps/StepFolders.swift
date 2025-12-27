// Views/Assistant/Modules/MailSetup/MailSetupSteps/StepFolders.swift
// AILO - Wizard Step 4: Folder Assignment (Produktive Implementierung)

import SwiftUI

struct StepFolders: View {
    @EnvironmentObject var state: MailSetupState
    @State private var isRefreshing: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .font(.system(size: 48))
                        .foregroundStyle(.teal.gradient)

                    Text("wizard.folders.title")
                        .font(.title2.bold())

                    Text("wizard.folders.subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Folder Assignments
                VStack(spacing: 0) {
                    FolderPickerRow(
                        icon: "tray.fill",
                        label: "wizard.folders.inbox",
                        selection: $state.folderInbox,
                        options: state.discoveredFolders,
                        isRequired: true
                    )

                    Divider().padding(.leading, 52)

                    FolderPickerRow(
                        icon: "paperplane.fill",
                        label: "wizard.folders.sent",
                        selection: $state.folderSent,
                        options: state.discoveredFolders
                    )

                    Divider().padding(.leading, 52)

                    FolderPickerRow(
                        icon: "doc.fill",
                        label: "wizard.folders.drafts",
                        selection: $state.folderDrafts,
                        options: state.discoveredFolders
                    )

                    Divider().padding(.leading, 52)

                    FolderPickerRow(
                        icon: "trash.fill",
                        label: "wizard.folders.trash",
                        selection: $state.folderTrash,
                        options: state.discoveredFolders
                    )

                    Divider().padding(.leading, 52)

                    FolderPickerRow(
                        icon: "xmark.bin.fill",
                        label: "wizard.folders.spam",
                        selection: $state.folderSpam,
                        options: state.discoveredFolders
                    )
                }
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                // Refresh Button
                Button {
                    Task {
                        await refreshFolders()
                    }
                } label: {
                    HStack {
                        if isRefreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("wizard.folders.refresh")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.teal)
                }
                .disabled(isRefreshing)
                .padding(.horizontal)

                // Discovered Folders Info
                if !state.discoveredFolders.isEmpty {
                    DiscoveredFoldersInfo(folders: state.discoveredFolders)
                        .padding(.horizontal)
                }

                // Success Message
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)

                    Text("wizard.folders.ready")
                        .font(.headline)

                    Text("wizard.folders.readySubtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
        }
    }

    // MARK: - Refresh Folders

    private func refreshFolders() async {
        isRefreshing = true

        let config = state.buildMailAccountConfig()

        let login = FolderDiscoveryService.IMAPLogin(
            host: config.recvHost,
            port: config.recvPort,
            useTLS: config.recvEncryption == .sslTLS,
            sniHost: config.recvHost,
            username: config.recvUsername,
            password: config.recvPassword ?? "",
            connectionTimeoutSec: config.connectionTimeoutSec,
            commandTimeoutSec: max(5, config.connectionTimeoutSec / 2),
            idleTimeoutSec: 10
        )

        let result = await FolderDiscoveryService.shared.listFoldersDetailed(
            accountId: state.accountId,
            login: login
        )

        switch result {
        case .success(let folders):
            state.discoveredFolders = folders.map { $0.name }
        case .failure(let error):
            print("⚠️ Folder refresh failed: \(error)")
        }

        isRefreshing = false
    }
}

// MARK: - Folder Picker Row

private struct FolderPickerRow: View {
    let icon: String
    let label: LocalizedStringKey
    @Binding var selection: String
    let options: [String]
    var isRequired: Bool = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.teal)
                .frame(width: 28)

            HStack(spacing: 4) {
                Text(label)
                    .font(.subheadline)

                if isRequired {
                    Text("*")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Spacer()

            Picker("", selection: $selection) {
                if !isRequired {
                    Text("wizard.folders.none").tag("")
                }
                ForEach(options, id: \.self) { folder in
                    Text(folder).tag(folder)
                }
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        }
        .padding()
    }
}

// MARK: - Discovered Folders Info

private struct DiscoveredFoldersInfo: View {
    let folders: [String]
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Image(systemName: folderIcon(for: folder))
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        Text(folder)
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)

                Text("wizard.folders.discovered")
                    .font(.subheadline)

                Text("\(folders.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func folderIcon(for folder: String) -> String {
        let lower = folder.lowercased()
        if lower == "inbox" { return "tray.fill" }
        if lower.contains("sent") { return "paperplane.fill" }
        if lower.contains("draft") { return "doc.fill" }
        if lower.contains("trash") || lower.contains("deleted") { return "trash.fill" }
        if lower.contains("spam") || lower.contains("junk") { return "xmark.bin.fill" }
        if lower.contains("archive") { return "archivebox.fill" }
        return "folder"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        StepFolders()
            .environmentObject({
                let state = MailSetupState()
                state.discoveredFolders = ["INBOX", "Sent", "Drafts", "Trash", "Spam", "Archive", "Notes"]
                state.folderInbox = "INBOX"
                state.folderSent = "Sent"
                return state
            }())
    }
}
