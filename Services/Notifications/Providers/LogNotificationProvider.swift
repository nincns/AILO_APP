// AILO_APP/Services/Notifications/Providers/LogNotificationProvider.swift
// Provider for log reminder notifications.

import Foundation

/// Provides notification creation for log entry reminders.
struct LogNotificationProvider {

    /// Creates a scheduled notification for a log reminder.
    /// - Parameters:
    ///   - entryId: The ID of the log entry
    ///   - title: The title of the log entry (optional)
    ///   - reminderDate: The date/time when the notification should appear
    /// - Returns: A configured AILONotification for scheduling
    static func createReminderNotification(
        entryId: UUID,
        title: String?,
        reminderDate: Date
    ) -> AILONotification {
        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notificationBody = displayTitle?.isEmpty == false
            ? displayTitle!
            : String(localized: "notification.reminder.defaultTitle")

        return AILONotification(
            id: notificationId(for: entryId),
            category: .logReminder,
            title: "🔔 " + String(localized: "notification.reminder.title"),
            subtitle: nil,
            body: notificationBody,
            badge: nil,  // Reminders don't change the badge
            sound: true,
            deepLink: .log(entryId: entryId),
            groupId: "log-reminders",
            scheduledDate: reminderDate
        )
    }

    /// Returns the notification ID for a given log entry.
    /// Use this for cancellation operations.
    /// - Parameter entryId: The ID of the log entry
    /// - Returns: The notification identifier string
    static func notificationId(for entryId: UUID) -> String {
        return "log-reminder-\(entryId.uuidString)"
    }
}
