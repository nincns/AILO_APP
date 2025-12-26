// Views/Configuration/JourneyCalendarSettingsView.swift
import SwiftUI
import EventKit

struct JourneyCalendarSettingsView: View {
    @State private var selectedCalendarId: String = ""
    @State private var selectedCalendarTitle: String = ""
    @State private var availableCalendars: [EKCalendar] = []
    @State private var calendarSources: [EKSource] = []
    @State private var permissionStatus: JourneyCalendarService.PermissionStatus = .notDetermined
    @State private var isLoading: Bool = true
    @State private var showCreateSheet: Bool = false
    @State private var newCalendarName: String = "AILO Journey"
    @State private var selectedSourceIndex: Int = 0
    @State private var createError: String?

    private let calendarService = JourneyCalendarService.shared

    var body: some View {
        List {
            // Berechtigungsstatus
            permissionSection

            if permissionStatus == .authorized {
                // Aktuell ausgewählter Kalender
                currentCalendarSection

                // Kalender erstellen
                createCalendarSection

                // Verfügbare Kalender
                availableCalendarsSection
            }
        }
        .navigationTitle(String(localized: "config.journey.calendar.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSettings()
            checkPermission()
        }
        .sheet(isPresented: $showCreateSheet) {
            createCalendarSheet
        }
    }

    // MARK: - Permission Section

    @ViewBuilder
    private var permissionSection: some View {
        Section {
            switch permissionStatus {
            case .authorized:
                Label(String(localized: "config.journey.calendar.accessGranted"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 12) {
                    Label(String(localized: "config.journey.calendar.accessDenied"), systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)

                    Text(String(localized: "config.journey.calendar.openSettings"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(String(localized: "config.journey.calendar.openSettingsButton")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

            case .notDetermined:
                Button {
                    Task {
                        _ = await calendarService.requestAccess()
                        checkPermission()
                    }
                } label: {
                    Label(String(localized: "config.journey.calendar.requestAccess"), systemImage: "calendar.badge.plus")
                }

            case .writeOnly:
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "config.journey.calendar.writeOnly"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(String(localized: "config.journey.calendar.writeOnlyHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "config.journey.calendar.permission"))
        }
    }

    // MARK: - Current Calendar Section

    @ViewBuilder
    private var currentCalendarSection: some View {
        Section {
            if !selectedCalendarId.isEmpty && !selectedCalendarTitle.isEmpty {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(calendarColor(for: selectedCalendarId))
                    Text(selectedCalendarTitle)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            } else {
                HStack {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text(String(localized: "config.journey.calendar.notSelected"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "config.journey.calendar.current"))
        } footer: {
            Text(String(localized: "config.journey.calendar.currentHint"))
        }
    }

    // MARK: - Create Calendar Section

    @ViewBuilder
    private var createCalendarSection: some View {
        Section {
            Button {
                showCreateSheet = true
            } label: {
                Label(String(localized: "config.journey.calendar.createNew"), systemImage: "plus.circle")
            }
        } footer: {
            Text(String(localized: "config.journey.calendar.createHint"))
        }
    }

    // MARK: - Available Calendars Section

    @ViewBuilder
    private var availableCalendarsSection: some View {
        Section {
            if isLoading {
                ProgressView()
            } else if availableCalendars.isEmpty {
                Text(String(localized: "config.journey.calendar.noCalendars"))
                    .foregroundStyle(.secondary)
            } else {
                // Gruppiert nach Source (Konto)
                ForEach(calendarsBySource.keys.sorted(by: { $0.title < $1.title }), id: \.sourceIdentifier) { source in
                    DisclosureGroup {
                        ForEach(calendarsBySource[source] ?? [], id: \.calendarIdentifier) { calendar in
                            calendarRow(calendar)
                        }
                    } label: {
                        Label(source.title, systemImage: sourceIcon(for: source))
                    }
                }
            }
        } header: {
            Text(String(localized: "config.journey.calendar.available"))
        }
    }

    private var calendarsBySource: [EKSource: [EKCalendar]] {
        Dictionary(grouping: availableCalendars) { $0.source }
    }

    @ViewBuilder
    private func calendarRow(_ calendar: EKCalendar) -> some View {
        Button {
            selectCalendar(calendar)
        } label: {
            HStack {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 12, height: 12)

                Text(calendar.title)
                    .foregroundStyle(.primary)

                Spacer()

                if calendar.calendarIdentifier == selectedCalendarId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Create Calendar Sheet

    @ViewBuilder
    private var createCalendarSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "config.journey.calendar.name"), text: $newCalendarName)
                        .onChange(of: newCalendarName) { _, _ in
                            createError = nil
                        }
                } header: {
                    Text(String(localized: "config.journey.calendar.nameHeader"))
                }

                Section {
                    if !writableSources.isEmpty {
                        Picker(String(localized: "config.journey.calendar.account"), selection: $selectedSourceIndex) {
                            ForEach(writableSources.indices, id: \.self) { index in
                                Label(writableSources[index].title, systemImage: sourceIcon(for: writableSources[index]))
                                    .tag(index)
                            }
                        }
                        .onChange(of: selectedSourceIndex) { _, _ in
                            createError = nil
                        }
                    } else {
                        Text(String(localized: "config.journey.calendar.noAccounts"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "config.journey.calendar.accountHeader"))
                } footer: {
                    Text(String(localized: "config.journey.calendar.accountHint"))
                }

                // Fehleranzeige
                if let error = createError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } footer: {
                        Text(String(localized: "config.journey.calendar.createErrorHint"))
                    }
                }
            }
            .navigationTitle(String(localized: "config.journey.calendar.createTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        showCreateSheet = false
                        createError = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.create")) {
                        createCalendar()
                    }
                    .disabled(newCalendarName.isEmpty || writableSources.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helpers

    /// Quellen die das Erstellen von Kalendern erlauben
    private var writableSources: [EKSource] {
        calendarSources.filter { source in
            // Nur Quellen die Kalender erstellen können
            switch source.sourceType {
            case .local:
                return true
            case .calDAV:
                // iCloud, Google etc. - meistens erlaubt
                return true
            case .exchange:
                // Exchange - kann eingeschränkt sein, aber versuchen
                return true
            case .subscribed, .birthdays:
                // Diese erlauben keine neuen Kalender
                return false
            @unknown default:
                return false
            }
        }
    }

    private func sourceIcon(for source: EKSource) -> String {
        switch source.sourceType {
        case .local: return "iphone"
        case .exchange: return "building.2"
        case .calDAV: return "cloud"
        case .subscribed: return "link"
        case .birthdays: return "gift"
        default: return "calendar"
        }
    }

    private func calendarColor(for identifier: String) -> Color {
        if let calendar = availableCalendars.first(where: { $0.calendarIdentifier == identifier }) {
            return Color(cgColor: calendar.cgColor)
        }
        return .gray
    }

    // MARK: - Actions

    private func loadSettings() {
        let ud = UserDefaults.standard
        selectedCalendarId = ud.string(forKey: kJourneyCalendarId) ?? ""
        selectedCalendarTitle = ud.string(forKey: kJourneyCalendarTitle) ?? ""
    }

    private func checkPermission() {
        permissionStatus = calendarService.permissionStatus

        if permissionStatus == .authorized {
            loadCalendars()
        }
    }

    private func loadCalendars() {
        isLoading = true

        // Alle Kalender und Sources laden
        let store = EKEventStore()
        availableCalendars = store.calendars(for: .event).filter { $0.allowsContentModifications }
        calendarSources = Array(store.sources)

        // Prüfen ob ausgewählter Kalender noch existiert
        if !selectedCalendarId.isEmpty {
            if !availableCalendars.contains(where: { $0.calendarIdentifier == selectedCalendarId }) {
                // Kalender wurde gelöscht - Auswahl zurücksetzen
                selectedCalendarId = ""
                selectedCalendarTitle = ""
                saveSettings()
            }
        }

        isLoading = false
    }

    private func selectCalendar(_ calendar: EKCalendar) {
        selectedCalendarId = calendar.calendarIdentifier
        selectedCalendarTitle = calendar.title
        saveSettings()
    }

    private func saveSettings() {
        let ud = UserDefaults.standard
        ud.set(selectedCalendarId, forKey: kJourneyCalendarId)
        ud.set(selectedCalendarTitle, forKey: kJourneyCalendarTitle)
    }

    private func createCalendar() {
        guard !newCalendarName.isEmpty,
              selectedSourceIndex < writableSources.count else { return }

        createError = nil

        let store = EKEventStore()
        let newCalendar = EKCalendar(for: .event, eventStore: store)
        newCalendar.title = newCalendarName
        newCalendar.source = writableSources[selectedSourceIndex]

        // AILO-Farbe setzen (Blau)
        newCalendar.cgColor = UIColor.systemBlue.cgColor

        do {
            try store.saveCalendar(newCalendar, commit: true)
            print("✅ Calendar created: \(newCalendar.calendarIdentifier)")

            // Neuen Kalender auswählen
            selectCalendar(newCalendar)

            // Liste aktualisieren
            loadCalendars()

            showCreateSheet = false
            createError = nil
            newCalendarName = "AILO Journey"
        } catch {
            print("❌ Failed to create calendar: \(error)")
            // Benutzerfreundliche Fehlermeldung
            createError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        JourneyCalendarSettingsView()
    }
}
