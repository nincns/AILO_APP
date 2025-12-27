// AILO_APP/Services/Notifications/Providers/LogNotificationProvider.swift
// Provider for log reminder notifications.

import Foundation

/// Provides notification creation for log entry reminders.
///
/// Banner Layout:
/// ```
/// ┌─────────────────────────────────────────────┐
/// │ LogReminder | [Title] | [Category]          │  ← Title line
/// │ First 70 chars of log text...               │  ← Body (preview)
/// └─────────────────────────────────────────────┘
/// ```
struct LogNotificationProvider {

    /// Creates a scheduled notification for a log reminder.
    ///
    /// Banner format:
    /// - Title: "LogReminder | [Titel] | [Kategorie]" (pipe-separated)
    /// - Body: First 70 characters of the log entry text
    ///
    /// - Parameters:
    ///   - entryId: The ID of the log entry
    ///   - title: The title of the log entry (optional)
    ///   - category: The category of the log entry (optional)
    ///   - bodyPreview: Preview text from the log entry body (optional)
    ///   - reminderDate: The date/time when the notification should appear
    /// - Returns: A configured AILONotification for scheduling
    static func createReminderNotification(
        entryId: UUID,
        title: String?,
        category: String?,
        bodyPreview: String?,
        reminderDate: Date
    ) -> AILONotification {
        // Banner Title: "LogReminder | [Titel] | [Kategorie]"
        var titleParts: [String] = ["LogReminder"]

        let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = displayTitle, !t.isEmpty {
            titleParts.append(t)
        }

        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
            titleParts.append(cat)
        }

        let notificationTitle = titleParts.joined(separator: " | ")

        // Banner Body: First 70 characters of log text (preview)
        let notificationBody: String
        if let preview = bodyPreview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
            notificationBody = String(preview.prefix(70))
        } else {
            notificationBody = ""
        }

        return AILONotification(
            id: notificationId(for: entryId),
            category: .logReminder,
            title: notificationTitle,
            subtitle: nil,
            body: notificationBody,
            badge: nil,
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
