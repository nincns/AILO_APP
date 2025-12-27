// AILO_APP/Services/Notifications/Providers/MailNotificationProvider.swift
// Creates AILONotification instances from new mail headers.

import Foundation

/// Provider for creating mail-specific notifications
public struct MailNotificationProvider {

    /// Create a notification from a mail header
    /// - Parameters:
    ///   - mail: The mail header to create notification for
    ///   - accountId: The account UUID
    ///   - accountName: Human-readable account name for subtitle
    ///   - folder: The folder where the mail was found
    /// - Returns: An AILONotification ready to be scheduled
    public static func createNotification(
        from mail: MailHeaderView,
        accountId: UUID,
        accountName: String,
        folder: String
    ) -> AILONotification {

        // Clean up sender name for display
        let senderDisplay = cleanSenderName(mail.from)

        // Truncate subject for notification body
        let subjectDisplay = String(mail.subject.prefix(100))

        return AILONotification(
            id: "mail-\(accountId.uuidString.prefix(8))-\(mail.id)",
            category: .mail,
            title: senderDisplay,
            subtitle: accountName,  // Shows account name when multiple accounts
            body: subjectDisplay,
            badge: 1,  // Each mail adds 1 to badge
            sound: true,
            deepLink: .mail(accountId: accountId, folder: folder, uid: mail.id),
            groupId: accountId.uuidString  // Group notifications by account
        )
    }

    /// Create notifications for multiple mails (with summary for large batches)
    /// - Parameters:
    ///   - mails: Array of mail headers
    ///   - accountId: The account UUID
    ///   - accountName: Human-readable account name
    ///   - folder: The folder where mails were found
    /// - Returns: Array of notifications (may include summary)
    public static func createNotifications(
        from mails: [MailHeaderView],
        accountId: UUID,
        accountName: String,
        folder: String
    ) -> [AILONotification] {

        // For small batches, create individual notifications
        if mails.count <= 3 {
            return mails.map { mail in
                createNotification(
                    from: mail,
                    accountId: accountId,
                    accountName: accountName,
                    folder: folder
                )
            }
        }

        // For larger batches, create a summary notification
        let summaryNotification = AILONotification(
            id: "mail-summary-\(accountId.uuidString.prefix(8))-\(Date().timeIntervalSince1970)",
            category: .mail,
            title: "\(mails.count) neue E-Mails",
            subtitle: accountName,
            body: createSummaryBody(from: mails),
            badge: mails.count,
            sound: true,
            deepLink: .mail(accountId: accountId, folder: folder, uid: mails.first?.id ?? ""),
            groupId: accountId.uuidString
        )

        return [summaryNotification]
    }

    // MARK: - Private Helpers

    /// Extract display name from email address
    /// "Max Mustermann <max@example.com>" → "Max Mustermann"
    /// "max@example.com" → "max@example.com"
    private static func cleanSenderName(_ from: String) -> String {
        // Try to extract name from "Name <email>" format
        if let angleBracket = from.firstIndex(of: "<") {
            let name = String(from[..<angleBracket]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != from {
                // Remove surrounding quotes if present
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return from
    }

    /// Create summary body listing first few senders
    private static func createSummaryBody(from mails: [MailHeaderView]) -> String {
        let firstFew = mails.prefix(3)
        let senders = firstFew.map { cleanSenderName($0.from) }

        if mails.count > 3 {
            return senders.joined(separator: ", ") + " und \(mails.count - 3) weitere"
        } else {
            return senders.joined(separator: ", ")
        }
    }
}
