import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SchreibenView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: DataStore

    // Basis
    @State private var title: String = ""
    @State private var text: String  = ""

    // Kategorie
    @State private var categories: [String] = []
    private let kCategories = "config.categories"
    @State private var category: String = String(localized: "write.category.default")
    @State private var showCategoriesSheet: Bool = false

    // Tags (Chips)
    @State private var tagInput: String = ""
    @State private var tags: [String] = []

    // Reminder
    @State private var reminderOn: Bool = false
    @State private var reminderDate: Date = Date().addingTimeInterval(3600)

    // UI
    @State private var showSaved = false

    private enum Field { case title, tagInput, editor }
    @FocusState private var focusedField: Field?

    // Assistant-Flow (schrittweises Ausfüllen)
    private enum Step { case title, tags, reminder, content }
    @State private var currentStep: Step = .title
    @State private var expandTitle: Bool = true
    @State private var expandTags: Bool = false
    @State private var expandReminder: Bool = false
    @State private var expandContent: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Titel
                HStack {
                    Text("write.header.newEntry")
                        .font(.title)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // 1) Titel & Kategorie
                DisclosureGroup(isExpanded: $expandTitle) {
                    VStack(alignment: .leading, spacing: 16) {
                        // Zeile 1: Titel (Label entfernt)
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(String(localized: "write.placeholder.title"), text: $title)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .overlay(
                                    HStack {
                                        Spacer()
                                        if !title.isEmpty {
                                            Button(action: { title = "" }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                            }
                                            .padding(.trailing, 8)
                                        }
                                    }
                                )
                                .submitLabel(.next)
                                .onSubmit { goto(.tags) }
                                .focused($focusedField, equals: .title)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Zeile 2: Kategorie-Dropdown (links) + Zahnrad & Weiter (rechts)
                        HStack(alignment: .center, spacing: 12) {
                            Picker(String(localized: "write.picker.category"), selection: $category) {
                                ForEach(categories.isEmpty ? [String(localized: "write.category.default")] : categories, id: \.self) { Text($0) }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                            .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 12)

                            Button { showCategoriesSheet = true } label: {
                                Image(systemName: "gearshape").imageScale(.medium)
                            }
                            .accessibilityLabel(Text("write.access.manageCategories"))

                            Button("write.action.next", action: { goto(.tags) })
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                } label: {
                    Text("write.section.title")
                        .font(.headline)
                }

                // 2) Schlagworte
                DisclosureGroup(isExpanded: $expandTags) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Label entfernt
                        WrapChips(tags: $tags)
                        HStack(spacing: 8) {
                            TextField(String(localized: "write.placeholder.newTag"), text: $tagInput, onCommit: {})
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .focused($focusedField, equals: .tagInput)
                                .frame(maxWidth: .infinity)
                                .submitLabel(.next)
                                .onSubmit {
                                    let t = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if t.isEmpty {
                                        goto(.reminder)
                                    } else {
                                        addTag()
                                        // zweites Return kann weitergehen
                                    }
                                }
                            Button("write.action.add", action: addTag)
                                .buttonStyle(.bordered)
                            Button("write.action.next", action: { goto(.reminder) })
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                } label: {
                    Text("write.section.tags")
                        .font(.headline)
                }

                // 3) Reminder
                DisclosureGroup(isExpanded: $expandReminder) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Labels entfernt; Switch + Weiter in einer Zeile
                        HStack {
                            Toggle("", isOn: $reminderOn)
                                .labelsHidden()
                            Spacer()
                            Button("write.action.next", action: { goto(.content) })
                                .buttonStyle(.bordered)
                        }
                        if reminderOn {
                            DatePicker(String(localized: "write.datepicker.label"), selection: $reminderDate, displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                } label: {
                    Text("write.section.reminder")
                        .font(.headline)
                }

                // 4) Inhalt
                DisclosureGroup(isExpanded: $expandContent) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Label entfernt, Editor mit weißem Hintergrund
                        TextEditor(text: $text)
                            .frame(minHeight: 160)
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.visible, axes: .vertical)
                            .background(colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color.white)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary))
                            .focused($focusedField, equals: .editor)
                        HStack {
                            // Einfügen aus Zwischenablage
                            Button {
                                importFromPasteboard()
                            } label: {
                                Label(String(localized: "write.action.paste"), systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            // Speichern rechts
                            Button("write.action.save", action: save)
                                .buttonStyle(.borderedProminent)
                                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .center)
                } label: {
                    Text("write.section.content")
                        .font(.headline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical)
        }
        .alert(String(localized: "write.alert.saved"), isPresented: $showSaved) { Button("common.ok", role: .cancel) {} }
        .sheet(isPresented: $showCategoriesSheet, onDismiss: { loadCategories() }) {
            NavigationStack { CategoriesView() }
        }
        .onAppear {
            loadCategories()
            goto(.title)
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            loadCategories()
        }
        .onChange(of: categories) { _, _ in
            if !categories.contains(category) {
                category = categories.first ?? String(localized: "write.category.default")
            }
        }
        .onTapGesture { focusedField = nil }
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer(minLength: 0)
                    Button(action: { focusedField = nil }) {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel(Text("write.access.hideKeyboard"))
                }
            }
        }
    }

    private func goto(_ step: Step) {
        currentStep = step
        // expand the selected section, collapse others
        expandTitle = (step == .title)
        expandTags = (step == .tags)
        expandReminder = (step == .reminder)
        expandContent = (step == .content)
        // set focus accordingly
        switch step {
        case .title:
            focusedField = .title
        case .tags:
            focusedField = .tagInput
        case .reminder:
            focusedField = nil
        case .content:
            focusedField = .editor
        }
    }

    // MARK: - Actions

    private func importFromPasteboard() {
#if canImport(UIKit)
        if let s = UIPasteboard.general.string {
            appendImported(s)
        }
#endif
    }

    private func appendImported(_ s: String) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.isEmpty {
            text = trimmed
        } else {
            // fügt mit sauberer Trennung an
            let needsNewline = !text.hasSuffix("\n")
            text += (needsNewline ? "\n" : "") + trimmed
        }
        // Fokus auf den Editor setzen
        goto(.content)
    }

    private func addTag() {
        let t = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !tags.contains(t) { tags.append(t) }
        tagInput = ""
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var entry = LogEntry.text(trimmed,
                                  title: title.isEmpty ? nil : title,
                                  category: category,
                                  tags: tags,
                                  reminderDate: reminderOn ? reminderDate : nil)
        entry.date = Date() // Datum + Uhrzeit beim Speichern
        store.add(entry)
        // (Optional: Reminder später via UserNotifications planen)

        showSaved = true

        // Felder zurücksetzen
        title = ""
        text = ""
        tags = []
        tagInput = ""
        category = categories.first ?? String(localized: "write.category.default")
        reminderOn = false
        // optional: reminderDate auf +1h zurücksetzen
        reminderDate = Date().addingTimeInterval(3600)
    }

    private func loadCategories() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: kCategories),
           let arr = try? JSONDecoder().decode([String].self, from: data),
           !arr.isEmpty {
            // Normalisieren: trimmen, Duplikate entfernen, leere raus
            let cleaned = arr
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let unique = Array(NSOrderedSet(array: cleaned)) as? [String] ?? cleaned
            categories = unique
        } else {
            categories = [
                String(localized: "write.category.default"),
                String(localized: "write.category.defaults.network"),
                String(localized: "write.category.defaults.docs")
            ]
        }
        // Auswahl absichern
        if !categories.contains(category) {
            category = categories.first ?? String(localized: "write.category.default")
        }
    }
}

// Kleine Chips-View (einfach und ohne Layout-Tricks)
private struct WrapChips: View {
    @Binding var tags: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 6) {
                        Text(tag).font(.caption)
                        Button("x") {
                            if let idx = tags.firstIndex(of: tag) { tags.remove(at: idx) }
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
    }
}
