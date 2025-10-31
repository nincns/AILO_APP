// Core/Models/LogEntry.swift
import Foundation
import Combine

@MainActor
final class DataStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published var pendingImportText: String? = nil
    private let fileName = "entries.json"

    init() {
        Task { await load() }
    }

    func add(_ entry: LogEntry) {
        entries.insert(entry, at: 0)
        Task { await save() }
    }

    func update(_ entry: LogEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
            Task { await save() }
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            if entries.indices.contains(index) {
                entries.remove(at: index)
            }
        }
        Task { await save() }
    }

    func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func storeURL() -> URL {
        documentsURL().appendingPathComponent(fileName)
    }

    func audioURL(for fileName: String) -> URL {
        documentsURL().appendingPathComponent(fileName)
    }

    func load() async {
        do {
            let url = storeURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([LogEntry].self, from: data)
            self.entries = decoded
        } catch {
            // optional: Logging
        }
    }

    func save() async {
        do {
            let url = storeURL()
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic])
        } catch {
            // optional: Logging
        }
    }
}
