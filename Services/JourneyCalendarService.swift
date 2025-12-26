// Services/JourneyCalendarService.swift
import Foundation
import EventKit

public final class JourneyCalendarService {

    public static let shared = JourneyCalendarService()

    private let store = EKEventStore()

    private init() {}

    // MARK: - Permission

    public enum PermissionStatus {
        case authorized
        case denied
        case notDetermined
        case restricted
        case writeOnly
    }

    public var permissionStatus: PermissionStatus {
        if #available(iOS 17.0, *) {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .authorized
            case .writeOnly: return .writeOnly
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            @unknown default: return .denied
            }
        } else {
            switch EKEventStore.authorizationStatus(for: .event) {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            @unknown default: return .denied
            }
        }
    }

    public func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            print("❌ Calendar access request failed: \(error)")
            return false
        }
    }

    // MARK: - Calendars

    /// Der in den Einstellungen konfigurierte Journey-Kalender
    public var configuredCalendar: EKCalendar? {
        guard let calendarId = UserDefaults.standard.string(forKey: kJourneyCalendarId),
              !calendarId.isEmpty else {
            return nil
        }
        return store.calendars(for: .event).first { $0.calendarIdentifier == calendarId }
    }

    /// Gibt den konfigurierten Kalender zurück, oder den System-Default
    public var journeyCalendar: EKCalendar? {
        configuredCalendar ?? store.defaultCalendarForNewEvents
    }

    /// Ob ein Journey-Kalender konfiguriert ist
    public var hasConfiguredCalendar: Bool {
        configuredCalendar != nil
    }

    public var defaultCalendar: EKCalendar? {
        store.defaultCalendarForNewEvents
    }

    public var availableCalendars: [EKCalendar] {
        store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    // MARK: - Create Event

    /// Erstellt Kalender-Event für Task (verwendet konfigurierten Journey-Kalender)
    public func createEvent(
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        notes: String? = nil,
        calendar: EKCalendar? = nil,
        alarm: TimeInterval? = -3600 // 1 Stunde vorher
    ) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title

        let actualEndDate = endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate

        // Prüfe ob ganztägig (Start 00:00 und Ende >= 23:00 am selben Tag)
        let cal = Calendar.current
        let startHour = cal.component(.hour, from: startDate)
        let startMinute = cal.component(.minute, from: startDate)
        let endHour = cal.component(.hour, from: actualEndDate)
        let isAllDay = startHour == 0 && startMinute == 0 && endHour >= 23

        if isAllDay {
            event.isAllDay = true
            event.startDate = cal.startOfDay(for: startDate)
            event.endDate = cal.startOfDay(for: startDate)  // Für ganztägig: gleiches Datum
        } else {
            event.isAllDay = false
            event.startDate = startDate
            event.endDate = actualEndDate
        }

        event.notes = notes
        // Verwendet übergebenen Kalender, oder konfigurierten Journey-Kalender
        event.calendar = calendar ?? journeyCalendar

        // Alarm hinzufügen (nur bei nicht-ganztägigen Events)
        if !isAllDay, let alarmOffset = alarm {
            event.addAlarm(EKAlarm(relativeOffset: alarmOffset))
        }

        try store.save(event, span: .thisEvent)
        print("✅ Calendar event created: \(event.eventIdentifier ?? "unknown") - allDay: \(isAllDay)")

        return event.eventIdentifier ?? ""
    }

    // MARK: - Update Event

    /// Aktualisiert bestehendes Event
    public func updateEvent(
        identifier: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        notes: String? = nil
    ) throws {
        guard let event = store.event(withIdentifier: identifier) else {
            throw CalendarError.eventNotFound
        }

        if let title = title {
            event.title = title
        }

        if let startDate = startDate {
            let actualEndDate = endDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate

            // Prüfe ob ganztägig (Start 00:00 und Ende >= 23:00)
            let cal = Calendar.current
            let startHour = cal.component(.hour, from: startDate)
            let startMinute = cal.component(.minute, from: startDate)
            let endHour = cal.component(.hour, from: actualEndDate)
            let isAllDay = startHour == 0 && startMinute == 0 && endHour >= 23

            if isAllDay {
                event.isAllDay = true
                event.startDate = cal.startOfDay(for: startDate)
                event.endDate = cal.startOfDay(for: startDate)
            } else {
                event.isAllDay = false
                event.startDate = startDate
                event.endDate = actualEndDate
            }
        } else if let endDate = endDate {
            event.endDate = endDate
        }

        if let notes = notes {
            event.notes = notes
        }

        try store.save(event, span: .thisEvent)
        print("✅ Calendar event updated: \(identifier)")
    }

    // MARK: - Delete Event

    /// Löscht Kalender-Event
    public func deleteEvent(identifier: String) throws {
        guard let event = store.event(withIdentifier: identifier) else {
            print("⚠️ Event not found for deletion: \(identifier)")
            return
        }

        try store.remove(event, span: .thisEvent)
        print("✅ Calendar event deleted: \(identifier)")
    }

    // MARK: - Fetch Event

    /// Lädt Event-Details
    public func fetchEvent(identifier: String) -> EKEvent? {
        store.event(withIdentifier: identifier)
    }

    // MARK: - Sync Task to Calendar

    /// Synchronisiert Task mit Kalender (erstellt oder aktualisiert)
    public func syncTask(_ node: JourneyNode) throws -> String? {
        guard node.nodeType == .task, let startDate = node.dueDate else {
            return nil
        }

        let notes = "AILO Journey Task\nStatus: \(node.status?.title ?? "Offen")"

        if let existingId = node.calendarEventId, !existingId.isEmpty {
            // Update
            try updateEvent(
                identifier: existingId,
                title: node.title,
                startDate: startDate,
                endDate: node.dueEndDate,
                notes: notes
            )
            return existingId
        } else {
            // Create
            return try createEvent(
                title: node.title,
                startDate: startDate,
                endDate: node.dueEndDate,
                notes: notes
            )
        }
    }

    // MARK: - Error

    public enum CalendarError: LocalizedError {
        case eventNotFound
        case noCalendarAccess
        case saveFailed(Error)

        public var errorDescription: String? {
            switch self {
            case .eventNotFound: return "Kalendereintrag nicht gefunden"
            case .noCalendarAccess: return "Kein Zugriff auf Kalender"
            case .saveFailed(let error): return "Speichern fehlgeschlagen: \(error.localizedDescription)"
            }
        }
    }
}
