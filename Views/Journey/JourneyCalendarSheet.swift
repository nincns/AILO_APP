// Views/Journey/JourneyCalendarSheet.swift
import SwiftUI
import EventKit

struct JourneyCalendarSheet: View {
    let node: JourneyNode
    let onEventCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: JourneyStore

    @State private var dueDate: Date
    @State private var hasReminder: Bool = true
    @State private var reminderOffset: TimeInterval = -3600 // 1h vorher
    @State private var selectedCalendar: EKCalendar?
    @State private var permissionDenied: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private let service = JourneyCalendarService.shared

    init(node: JourneyNode, onEventCreated: @escaping (String) -> Void) {
        self.node = node
        self.onEventCreated = onEventCreated
        _dueDate = State(initialValue: node.dueDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                if permissionDenied {
                    permissionDeniedSection
                } else {
                    eventDetailsSection
                    reminderSection
                    calendarSection

                    if let error = errorMessage {
                        Section {
                            Text(error)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "journey.calendar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.create")) {
                        createEvent()
                    }
                    .disabled(permissionDenied || isLoading)
                }
            }
            .task {
                await checkPermission()
            }
        }
    }

    // MARK: - Sections

    private var permissionDeniedSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 50))
                    .foregroundStyle(.red)

                Text(String(localized: "journey.calendar.noAccess"))
                    .font(.headline)

                Text(String(localized: "journey.calendar.noAccess.message"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(String(localized: "common.openSettings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
    }

    private var eventDetailsSection: some View {
        Section(String(localized: "journey.calendar.details")) {
            HStack {
                Text(String(localized: "journey.detail.title"))
                Spacer()
                Text(node.title)
                    .foregroundStyle(.secondary)
            }

            DatePicker(
                String(localized: "journey.calendar.datetime"),
                selection: $dueDate,
                displayedComponents: [.date, .hourAndMinute]
            )
        }
    }

    private var reminderSection: some View {
        Section(String(localized: "journey.calendar.reminder")) {
            Toggle(String(localized: "journey.calendar.reminder"), isOn: $hasReminder)

            if hasReminder {
                Picker(String(localized: "journey.calendar.when"), selection: $reminderOffset) {
                    Text(String(localized: "journey.calendar.reminder.15min")).tag(TimeInterval(-900))
                    Text(String(localized: "journey.calendar.reminder.30min")).tag(TimeInterval(-1800))
                    Text(String(localized: "journey.calendar.reminder.1h")).tag(TimeInterval(-3600))
                    Text(String(localized: "journey.calendar.reminder.1d")).tag(TimeInterval(-86400))
                }
            }
        }
    }

    private var calendarSection: some View {
        Section(String(localized: "journey.calendar")) {
            if service.availableCalendars.isEmpty {
                Text(String(localized: "journey.calendar.noCalendars"))
                    .foregroundStyle(.secondary)
            } else {
                Picker(String(localized: "journey.calendar"), selection: $selectedCalendar) {
                    ForEach(service.availableCalendars, id: \.calendarIdentifier) { calendar in
                        HStack {
                            Circle()
                                .fill(Color(cgColor: calendar.cgColor))
                                .frame(width: 12, height: 12)
                            Text(calendar.title)
                        }
                        .tag(calendar as EKCalendar?)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func checkPermission() async {
        switch service.permissionStatus {
        case .authorized, .writeOnly:
            permissionDenied = false
            selectedCalendar = service.defaultCalendar
        case .notDetermined:
            let granted = await service.requestAccess()
            permissionDenied = !granted
            if granted {
                selectedCalendar = service.defaultCalendar
            }
        default:
            permissionDenied = true
        }
    }

    private func createEvent() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let eventId = try service.createEvent(
                    title: node.title,
                    startDate: dueDate,
                    notes: "AILO Journey Task",
                    calendar: selectedCalendar,
                    alarm: hasReminder ? reminderOffset : nil
                )

                await MainActor.run {
                    onEventCreated(eventId)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    JourneyCalendarSheet(
        node: JourneyNode(
            section: .projects,
            nodeType: .task,
            title: "Test Task",
            dueDate: Date()
        ),
        onEventCreated: { _ in }
    )
    .environmentObject(JourneyStore.shared)
}
