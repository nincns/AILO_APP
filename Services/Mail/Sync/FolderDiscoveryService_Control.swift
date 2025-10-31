import Foundation

extension Notification.Name {
    static let folderDiscoveryCancelAll = Notification.Name("FolderDiscoveryService.cancelAll")
    static let folderDiscoveryPauseAccount = Notification.Name("FolderDiscoveryService.pauseAccount")
    static let folderDiscoveryResumeAccount = Notification.Name("FolderDiscoveryService.resumeAccount")
    static let folderDiscoveryCancelAccount = Notification.Name("FolderDiscoveryService.cancelAccount")
}

public extension FolderDiscoveryService {
    /// Requests all discovery connections to close and prevents immediate restarts until the service decides to resume.
    func cancelAll() {
        NotificationCenter.default.post(name: .folderDiscoveryCancelAll, object: nil)
    }

    /// Pause discovery for a specific account.
    func pause(accountId: UUID) {
        NotificationCenter.default.post(name: .folderDiscoveryPauseAccount, object: accountId)
    }

    /// Resume discovery for a specific account.
    func resume(accountId: UUID) {
        NotificationCenter.default.post(name: .folderDiscoveryResumeAccount, object: accountId)
    }

    /// Cancel any active discovery connection for a specific account.
    func cancel(accountId: UUID) {
        NotificationCenter.default.post(name: .folderDiscoveryCancelAccount, object: accountId)
    }
}

/// Suggested wiring for FolderDiscoveryService (implement inside the service file):
/// - Observe the above notifications and perform the appropriate actions:
///     - cancelAll: close all active connections and mark service paused
///     - pauseAccount: add accountId to a paused set
///     - resumeAccount: remove accountId from paused set
///     - cancelAccount: close the connection for that account if active
/// This file only provides the signaling interface to avoid coupling to internal implementation.
