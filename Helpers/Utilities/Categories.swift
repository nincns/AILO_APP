import SwiftUI

/// Muss zu den übrigen Keys der App passen
private let kCategoriesKey = "config.categories"
private let kDefaultCategories: [String] = ["Allgemein", "Netzwerk", "Dokumentation"]

struct CategoriesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var categories: [String] = []
    @State private var newCategory: String = ""

    var body: some View {
        List {
            // Eingabezeile zum Anlegen
            Section {
                HStack(spacing: 12) {
                    TextField(String(localized: "categories.field.placeholder"), text: $newCategory)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        addCategory()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            // Bestehende Kategorien
            Section(header: Text("categories.title")) {
                if categories.isEmpty {
                    Text("categories.list.empty")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(categories.indices, id: \.self) { i in
                        Text(categories[i])
                    }
                    .onDelete(perform: delete)
                    .onMove(perform: move)
                }
            }
        }
        .navigationTitle(Text("categories.title"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { Button("common.done") { dismiss() } }
        }
        .onAppear(perform: load)
    }

    // MARK: - Actions

    private func addCategory() {
        let t = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        categories.append(t)
        newCategory = ""
        persist()
    }

    private func delete(at offsets: IndexSet) {
        categories.remove(atOffsets: offsets)
        persist()
    }

    private func move(from source: IndexSet, to destination: Int) {
        categories.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: - Persistence
    private func load() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: kCategoriesKey),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            categories = arr
        } else {
            categories = kDefaultCategories
        }
    }

    private func persist() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(categories) {
            ud.set(data, forKey: kCategoriesKey)
        }
    }
}
