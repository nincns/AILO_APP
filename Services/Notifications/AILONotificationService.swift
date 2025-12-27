// AILO_APP/Services/Notifications/AILONotificationService.swift
// Central notification manager for all AILO notifications.
// Handles permission, scheduling, badge management, and notification actions.

import Foundation
import UserNotifications
import UIKit

@MainActor
public final class AILONotificationService: NSObject {

    // MARK: - Singleton

    public static let shared = AILONotificationService()
    private override init() {
        super.init()
    }

    // MARK: - Properties

    private let center = UNUserNotificationCenter.current()
    private var currentBadgeCount: Int = 0

    // MARK: - Permission

    /// Request notification permission from the user
    public func requestPermission() async -> Bool {
        print("🔔 [Notification] Requesting permission...")

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            print("🔔 [Notification] Permission \(granted ? "granted ✅" : "denied ❌")")
            return granted
        } catch {
            print("🔔 [Notification] ❌ Permission request failed: \(error)")
            return false
        }
    }

    /// Check current notification permission status
    public func checkPermissionStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Setup

    /// Setup notification categories with actions. Call on app launch.
    public func setupCategories() {
        print("🔔 [Notification] Setting up categories...")

        // Mail category with actions
        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ",
            title: "Als gelesen markieren",
            options: []
        )
        let archiveAction = UNNotificationAction(
            identifier: "ARCHIVE",
            title: "Archivieren",
            options: [.destructive]
        )

        let mailCategory = UNNotificationCategory(
            identifier: AILONotification.Category.mail.identifier,
            actions: [markReadAction, archiveAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        // System category (no actions)
        let systemCategory = UNNotificationCategory(
            identifier: AILONotification.Category.system.identifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([mailCategory, systemCategory])
        center.delegate = self

        print("🔔 [Notification] ✅ Categories configured")
    }

    // MARK: - Scheduling

    /// Schedule a single notification
    public func schedule(_ notification: AILONotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        if let subtitle = notification.subtitle {
            content.subtitle = subtitle
        }
        content.body = notification.body
        content.categoryIdentifier = notification.category.identifier

        if notification.sound {
            content.sound = .default
        }

        // Set thread identifier for grouping
        if let groupId = notification.groupId {
            content.threadIdentifier = groupId
        }

        // Add deep link data
        content.userInfo = notification.deepLink.userInfo

        // Update badge
        if let badge = notification.badge {
            currentBadgeCount += badge
            content.badge = NSNumber(value: currentBadgeCount)
        }

        // Create trigger (immediate)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("🔔 [Notification] ❌ Failed to schedule: \(error)")
            } else {
                print("🔔 [Notification] ✅ Scheduled: \(notification.title)")
            }
        }
    }

    /// Schedule multiple notifications (respects iOS limit of 64 pending)
    public func scheduleMultiple(_ notifications: [AILONotification]) {
        print("🔔 [Notification] Scheduling \(notifications.count) notifications...")

        // iOS allows max 64 pending notifications
        let maxNotifications = 64
        let toSchedule = Array(notifications.prefix(maxNotifications))

        if notifications.count > maxNotifications {
            print("🔔 [Notification] ⚠️ Limiting to \(maxNotifications) notifications (iOS limit)")
        }

        for notification in toSchedule {
            schedule(notification)
        }

        print("🔔 [Notification] ✅ Scheduled \(toSchedule.count) notifications")
    }

    // MARK: - Badge Management

    /// Set badge to specific count
    public func updateBadge(count: Int) {
        currentBadgeCount = count
        UIApplication.shared.applicationIconBadgeNumber = count
        print("🔔 [Notification] Badge updated to: \(count)")
    }

    /// Increment badge by amount
    public func incrementBadge(by amount: Int) {
        currentBadgeCount += amount
        UIApplication.shared.applicationIconBadgeNumber = currentBadgeCount
        print("🔔 [Notification] Badge incremented to: \(currentBadgeCount)")
    }

    /// Clear badge
    public func clearBadge() {
        currentBadgeCount = 0
        UIApplication.shared.applicationIconBadgeNumber = 0
        print("🔔 [Notification] Badge cleared")
    }

    // MARK: - Cleanup

    /// Remove all pending and delivered notifications for a category
    public func removeNotifications(for category: AILONotification.Category) {
        center.getDeliveredNotifications { notifications in
            let toRemove = notifications
                .filter { $0.request.content.categoryIdentifier == category.identifier }
                .map { $0.request.identifier }

            self.center.removeDeliveredNotifications(withIdentifiers: toRemove)
            self.center.removePendingNotificationRequests(withIdentifiers: toRemove)

            print("🔔 [Notification] Removed \(toRemove.count) notifications for \(category.rawValue)")
        }
    }

    /// Remove all notifications
    public func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        clearBadge()
        print("🔔 [Notification] All notifications removed")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AILONotificationService: UNUserNotificationCenterDelegate {

    /// Handle notification tap
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier

        print("🔔 [Notification] Received action: \(actionId)")

        // Handle actions
        switch actionId {
        case "MARK_READ":
            print("🔔 [Notification] User tapped 'Mark as Read'")
            // TODO: Mark mail as read via MailRepository

        case "ARCHIVE":
            print("🔔 [Notification] User tapped 'Archive'")
            // TODO: Archive mail via MailRepository

        case UNNotificationDefaultActionIdentifier:
            // User tapped the notification itself
            let deepLink = AILONotification.DeepLink.from(userInfo: userInfo)
            print("🔔 [Notification] Deep link: \(deepLink)")

            // Post notification for navigation
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .ailoDeepLinkNavigation,
                    object: nil,
                    userInfo: ["deepLink": deepLink]
                )
            }

        case UNNotificationDismissActionIdentifier:
            print("🔔 [Notification] Notification dismissed")

        default:
            break
        }
    }

    /// Show notification when app is in foreground
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        print("🔔 [Notification] Presenting in foreground: \(notification.request.content.title)")
        return [.banner, .badge, .sound]
    }
}
