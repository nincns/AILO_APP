// AILO_APP/Services/Background/BackgroundTaskManager.swift
// Manages iOS Background App Refresh for mail synchronization.
// Uses BGTaskScheduler for system-controlled background updates.

import Foundation
import BackgroundTasks
import UIKit

@MainActor
public final class BackgroundTaskManager {

    // MARK: - Singleton
    public static let shared = BackgroundTaskManager()
    private init() {}

    // MARK: - Task Identifiers
    public static let appRefreshTaskId = "com.ailo.mail.refresh"
    public static let processingTaskId = "com.ailo.mail.processing"

    // MARK: - Registration

    /// Register background tasks with the system. MUST be called before app finishes launching.
    public func registerTasks() {
        print("📬 [BGTask] Registering background tasks...")

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.appRefreshTaskId,
            using: nil
        ) { task in
            Task { @MainActor in
                await self.handleAppRefresh(task: task as! BGAppRefreshTask)
            }
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskId,
            using: nil
        ) { task in
            Task { @MainActor in
                await self.handleProcessingTask(task: task as! BGProcessingTask)
            }
        }

        print("📬 [BGTask] ✅ Background tasks registered")
    }

    // MARK: - Scheduling

    /// Schedule a short app refresh task (runs ~30 seconds max)
    public func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.appRefreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes

        do {
            try BGTaskScheduler.shared.submit(request)
            print("📬 [BGTask] ✅ App refresh scheduled for ~15 min from now")
        } catch {
            print("📬 [BGTask] ❌ Failed to schedule app refresh: \(error)")
        }
    }

    /// Schedule a longer processing task (runs several minutes)
    public func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        do {
            try BGTaskScheduler.shared.submit(request)
            print("📬 [BGTask] ✅ Processing task scheduled for ~1 hour from now")
        } catch {
            print("📬 [BGTask] ❌ Failed to schedule processing task: \(error)")
        }
    }

    // MARK: - Task Handlers

    /// Handle short app refresh (~30 seconds budget)
    private func handleAppRefresh(task: BGAppRefreshTask) async {
        print("📬 [BGTask] ▶️ App refresh started")

        // Schedule next refresh immediately
        scheduleAppRefresh()

        // Set expiration handler
        task.expirationHandler = {
            print("📬 [BGTask] ⚠️ App refresh expired")
            task.setTaskCompleted(success: false)
        }

        // Perform quick sync (INBOX only, limited mails)
        let success = await performQuickSync()

        print("📬 [BGTask] App refresh completed: \(success ? "✅" : "❌")")
        task.setTaskCompleted(success: success)
    }

    /// Handle longer processing task (several minutes)
    private func handleProcessingTask(task: BGProcessingTask) async {
        print("📬 [BGTask] ▶️ Processing task started")

        // Schedule next processing task
        scheduleProcessingTask()

        // Set expiration handler
        task.expirationHandler = {
            print("📬 [BGTask] ⚠️ Processing task expired")
            task.setTaskCompleted(success: false)
        }

        // Perform full sync (all folders)
        let success = await performFullSync()

        print("📬 [BGTask] Processing task completed: \(success ? "✅" : "❌")")
        task.setTaskCompleted(success: success)
    }

    // MARK: - Sync Operations

    /// Quick sync: INBOX only, limited to 20 new mails per account
    private func performQuickSync() async -> Bool {
        print("📬 [BGTask] Performing quick sync (INBOX only)...")

        let activeIds = getActiveAccountIds()
        guard !activeIds.isEmpty else {
            print("📬 [BGTask] No active accounts to sync")
            return true
        }

        print("📬 [BGTask] Syncing \(activeIds.count) active account(s)")

        var allSuccess = true
        var allNewMails: [AILONotification] = []

        for accountId in activeIds {
            do {
                let results = try await MailRepository.shared.backgroundFetchNewMails(
                    accountId: accountId,
                    folders: ["INBOX"],
                    limit: 20
                )

                // Create notifications for new mails
                for result in results {
                    let notifications = MailNotificationProvider.createNotifications(
                        from: result.newMails,
                        accountId: accountId,
                        accountName: result.accountName,
                        folder: result.folder
                    )
                    allNewMails.append(contentsOf: notifications)
                    print("📬 [BGTask] Account \(accountId.uuidString.prefix(8)): \(result.newMails.count) new mails")
                }
            } catch {
                print("📬 [BGTask] ❌ Failed to sync account \(accountId.uuidString.prefix(8)): \(error)")
                allSuccess = false
            }
        }

        // Schedule notifications for all new mails
        if !allNewMails.isEmpty {
            print("📬 [BGTask] 🔔 Scheduling \(allNewMails.count) notification(s)")
            await AILONotificationService.shared.scheduleMultiple(allNewMails)
        }

        return allSuccess
    }

    /// Full sync: All standard folders
    private func performFullSync() async -> Bool {
        print("📬 [BGTask] Performing full sync (all folders)...")

        let activeIds = getActiveAccountIds()
        guard !activeIds.isEmpty else {
            print("📬 [BGTask] No active accounts to sync")
            return true
        }

        print("📬 [BGTask] Full sync for \(activeIds.count) active account(s)")

        var allSuccess = true
        var allNewMails: [AILONotification] = []

        for accountId in activeIds {
            do {
                // Get folder map for this account
                let folders = ["INBOX", "Sent", "Drafts"] // Standard folders
                let results = try await MailRepository.shared.backgroundFetchNewMails(
                    accountId: accountId,
                    folders: folders,
                    limit: 50
                )

                // Create notifications for new mails (only INBOX for notifications)
                for result in results where result.folder == "INBOX" {
                    let notifications = MailNotificationProvider.createNotifications(
                        from: result.newMails,
                        accountId: accountId,
                        accountName: result.accountName,
                        folder: result.folder
                    )
                    allNewMails.append(contentsOf: notifications)
                    print("📬 [BGTask] Account \(accountId.uuidString.prefix(8)): \(result.newMails.count) new mails")
                }
            } catch {
                print("📬 [BGTask] ❌ Failed to sync account \(accountId.uuidString.prefix(8)): \(error)")
                allSuccess = false
            }
        }

        // Schedule notifications for all new mails
        if !allNewMails.isEmpty {
            print("📬 [BGTask] 🔔 Scheduling \(allNewMails.count) notification(s)")
            await AILONotificationService.shared.scheduleMultiple(allNewMails)
        }

        return allSuccess
    }

    // MARK: - Helpers

    /// Get IDs of all active mail accounts
    private func getActiveAccountIds() -> [UUID] {
        // Load active account IDs from UserDefaults (same key as MailManager)
        let activeKey = "mail.accounts.active"
        guard let data = UserDefaults.standard.data(forKey: activeKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            print("📬 [BGTask] No active accounts found in UserDefaults")
            return []
        }
        return ids
    }
}
