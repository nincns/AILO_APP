// AppBadgeManager.swift - Manages app icon badge for unread mail count
import Foundation
import UserNotifications
import UIKit

/// Manages the app icon badge number for unread mail notifications
@MainActor
final class AppBadgeManager {
    static let shared = AppBadgeManager()

    private var isAuthorized = false

    private init() {}

    // MARK: - Permission Request

    /// Requests notification permission for badge updates
    /// Call this on app startup
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()

        do {
            // Request badge permission (no alerts or sounds needed)
            let granted = try await center.requestAuthorization(options: [.badge])
            isAuthorized = granted

            if granted {
                print("✅ [AppBadgeManager] Badge permission granted")
            } else {
                print("⚠️ [AppBadgeManager] Badge permission denied by user")
            }
        } catch {
            print("❌ [AppBadgeManager] Permission request failed: \(error)")
            isAuthorized = false
        }
    }

    /// Checks current authorization status
    func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        isAuthorized = settings.badgeSetting == .enabled
    }

    // MARK: - Badge Update

    /// Updates the app icon badge with the unread count
    /// - Parameter count: Number of unread messages (0 clears the badge)
    func updateBadge(count: Int) {
        // Ensure we're on main thread for UI updates
        Task { @MainActor in
            if #available(iOS 16.0, *) {
                UNUserNotificationCenter.current().setBadgeCount(count) { error in
                    if let error = error {
                        print("❌ [AppBadgeManager] Failed to set badge: \(error)")
                    }
                }
            } else {
                // Fallback for iOS 15 and earlier
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }

    /// Clears the app icon badge
    func clearBadge() {
        updateBadge(count: 0)
    }

    // MARK: - Convenience

    /// Updates badge with total unread count across all accounts
    /// Call this after syncing mail or when unread count changes
    func updateFromUnreadCount(_ unreadCount: Int) {
        updateBadge(count: unreadCount)
    }
}
