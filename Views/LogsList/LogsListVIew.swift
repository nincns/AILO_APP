import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct LogsListView: View {
    @EnvironmentObject private var store: DataStore
    @State private var alert: (title: String, message: String)?
    @State private var showMail = false
    @State private var mailSubject: String = ""
    @State private var mailBody: String = ""
    @State private var mailComposerID: Int = 0
    @State private var selectedTextEntry: LogEntry? = nil
    @State private var showPlayer = false
    @State private var playerURL: URL?
    @State private var playerTitle: String = "Audio"
    @State private var searchText: String = ""
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.dateFormat = "dd.MM.yyyy, HH:mm"
        return df
    }()
    
    private func matches(_ entry: LogEntry, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        // Title
        if let t = entry.title?.lowercased(), t.contains(q) { return true }
        // AI text first (wenn vorhanden), sonst Originaltext
        if let ai = entry.aiText?.lowercased(), ai.contains(q) { return true }
        if let tx = entry.text?.lowercased(), tx.contains(q) { return true }
        // Audio-Dateiname
        if let f = entry.audioFileName?.lowercased(), f.contains(q) { return true }
        // Datum als String (wie in der Liste gezeigt)
        let dateStr = dateFormatter.string(from: entry.date).lowercased()
        if dateStr.contains(q) { return true }
        return false
    }
    
    private var filteredEntries: [LogEntry] {
        store.entries.filter { matches($0, query: searchText) }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            VStack(spacing: 6) {
                HStack {
                    Text(String(localized: "logs.list.title"))
                        .font(.title)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Text(String(localized: "logs.list.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 4)

            VStack {
                // Suche
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(String(localized: "logs.search.placeholder"), text: $searchText)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator).opacity(0.25))
                )
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)

                // Content
                List {
                    ForEach(filteredEntries) { entry in
                        switch entry.type {
                        case .text:
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title ?? String(localized: "logs.item.fallback.text"))
                                    .font(.headline)
                                let preview = preferredText(for: entry)
                                if !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(preview)
                                        .lineLimit(3)
                                }
                                Text(dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(10)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray6))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { selectedTextEntry = entry }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    prepareMail(for: entry)
                                } label: {
                                    Label(String(localized: "logs.action.mail"), systemImage: "envelope")
                                }.tint(.blue)
                            }

                        case .audio:
                            HStack(spacing: 16) {
                                Button {
                                    play(entry: entry)
                                } label: {
                                    Label(String(localized: "logs.action.play"), systemImage: "play.circle")
                                }
                                .buttonStyle(.bordered)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title ?? String(localized: "logs.item.fallback.audio"))
                                        .font(.headline)
                                    Text(dateFormatter.string(from: entry.date))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(10)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color(.systemGray6))
                            )
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    prepareMail(for: entry)
                                } label: {
                                    Label(String(localized: "logs.action.mail"), systemImage: "envelope")
                                }.tint(.blue)
                            }
                        }
                    }
                    .onDelete(perform: store.delete)
                }
                .listStyle(.plain)
                .listRowSeparator(.hidden)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(.horizontal)
        .padding(.top, 0)
        .alert(item: Binding(
            get: {
                alert.map { IdentifiedAlert(id: UUID(), title: $0.title, message: $0.message) }
            },
            set: { _ in alert = nil })
        ) { ia in
            Alert(title: Text(ia.title), message: Text(ia.message), dismissButton: .default(Text("common.ok")))
        }
        .sheet(isPresented: $showMail) {
            MailComposer(subject: mailSubject, body: mailBody, attachments: mailAttachments)
                .id(mailComposerID)
        }
        .sheet(isPresented: $showPlayer) {
            if let url = playerURL {
                AudioPlayerView(url: url, title: playerTitle)
            }
        }
        .sheet(item: $selectedTextEntry) { entry in
            TextLogDetailView(entry: entry)
                .environmentObject(store)
        }
    }
    
    private func preferredText(for entry: LogEntry) -> String {
        let ai = (entry.aiText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let useAI = entry.useAI ?? false
        return useAI ? (ai.isEmpty ? raw : ai) : raw
    }
    
    private func recomputeMailComposerID() {
        var hasher = Hasher()
        hasher.combine(mailSubject)
        hasher.combine(mailBody)
        hasher.combine(mailAttachments.count)
        // Include attachment filenames and sizes (not data bytes) for a stable but fast hash
        for att in mailAttachments {
            hasher.combine(att.fileName)
        }
        mailComposerID = hasher.finalize()
    }
    
    @State private var mailAttachments: [MailComposer.Attachment] = []
    private func prepareMail(for entry: LogEntry) {
        let title = entry.title ?? (entry.type == .audio ? String(localized: "logs.item.fallback.audio") : String(localized: "logs.mail.fallback.log"))
        self.mailSubject = title
        let when = dateFormatter.string(from: entry.date)
        switch entry.type {
        case .text:
            let body = preferredText(for: entry)
            self.mailBody = "\(String(localized: "logs.mail.body.titlePrefix")) \(title)\n\(String(localized: "logs.mail.body.datePrefix")) \(when)\n\n\(body)"
            self.mailAttachments = []
        case .audio:
            let name = entry.audioFileName ?? String(localized: "logs.mail.fallback.untitledAudio")
            let url = store.audioURL(for: name)
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url) {
                let attachment = MailComposer.Attachment(data: data, mimeType: "audio/m4a", fileName: name)
                self.mailBody = "\(String(localized: "logs.mail.body.titlePrefix")) \(title)\n\(String(localized: "logs.mail.body.datePrefix")) \(when)\n\(String(localized: "logs.mail.body.filePrefix")) \(name)"
                self.mailAttachments = [attachment]
            } else {
                self.mailBody = "\(String(localized: "logs.mail.body.titlePrefix")) \(title)\n\(String(localized: "logs.mail.body.datePrefix")) \(when)\n\(String(localized: "logs.mail.body.filePrefix")) \(name)\n\n\(String(localized: "logs.mail.body.audioNote"))"
                self.mailAttachments = []
            }
        }
        // Force a fresh MailComposer instance for the first real content
        self.recomputeMailComposerID()
        DispatchQueue.main.async {
            self.showMail = true
        }
    }
    
    private func play(entry: LogEntry) {
        guard let name = entry.audioFileName else { return }
        let url = store.audioURL(for: name)
        if FileManager.default.fileExists(atPath: url.path) {
            playerURL = url
            playerTitle = entry.title ?? String(localized: "logs.item.fallback.audio")
            showPlayer = true
        } else {
            alert = (String(localized: "logs.alert.audioTitle"), String(localized: "logs.alert.fileMissing"))
        }
    }
}

// Helper to present alerts with .alert(item:)
private struct IdentifiedAlert: Identifiable {
    let id: UUID
    let title: String
    let message: String
}
