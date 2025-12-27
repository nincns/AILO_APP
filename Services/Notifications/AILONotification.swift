// AILO_APP/Services/Notifications/AILONotification.swift
// Model for all AILO notifications with support for different categories.

import Foundation

/// Represents a notification that can be displayed to the user.
public struct AILONotification {
    public let id: String
    public let category: Category
    public let title: String
    public let subtitle: String?
    public let body: String
    public let badge: Int?
    public let sound: Bool
    public let deepLink: DeepLink
    public let groupId: String?
    public let scheduledDate: Date?  // For timed notifications (reminders)

    public init(
        id: String,
        category: Category,
        title: String,
        subtitle: String? = nil,
        body: String,
        badge: Int? = nil,
        sound: Bool = true,
        deepLink: DeepLink = .none,
        groupId: String? = nil,
        scheduledDate: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.badge = badge
        self.sound = sound
        self.deepLink = deepLink
        self.groupId = groupId
        self.scheduledDate = scheduledDate
    }

    // MARK: - Category

    /// Notification categories for grouping and handling
    public enum Category: String {
        case mail = "AILO_MAIL"
        case assistant = "AILO_ASSISTANT"      // Future: AI Assistant responses
        case scheduledTask = "AILO_TASK"       // Future: Scheduled task reminders
        case logReminder = "AILO_LOG_REMINDER" // Log entry reminders
        case system = "AILO_SYSTEM"

        /// Human-readable identifier for UNNotificationCategory
        public var identifier: String { rawValue }
    }

    // MARK: - DeepLink

    /// Deep link destinations for notification taps
    public enum DeepLink {
        case mail(accountId: UUID, folder: String, uid: String)
        case journey(nodeId: UUID)
        case log(entryId: UUID)
        case none

        /// Convert to userInfo dictionary for UNNotificationContent
        public var userInfo: [String: String] {
            switch self {
            case .mail(let accountId, let folder, let uid):
                return [
                    "type": "mail",
                    "accountId": accountId.uuidString,
                    "folder": folder,
                    "uid": uid
                ]
            case .journey(let nodeId):
                return [
                    "type": "journey",
                    "nodeId": nodeId.uuidString
                ]
            case .log(let entryId):
                return [
                    "type": "log",
                    "entryId": entryId.uuidString
                ]
            case .none:
                return [:]
            }
        }

        /// Parse from userInfo dictionary
        public static func from(userInfo: [AnyHashable: Any]) -> DeepLink {
            guard let type = userInfo["type"] as? String else { return .none }

            switch type {
            case "mail":
                guard let accountIdStr = userInfo["accountId"] as? String,
                      let accountId = UUID(uuidString: accountIdStr),
                      let folder = userInfo["folder"] as? String,
                      let uid = userInfo["uid"] as? String else {
                    return .none
                }
                return .mail(accountId: accountId, folder: folder, uid: uid)

            case "journey":
                guard let nodeIdStr = userInfo["nodeId"] as? String,
                      let nodeId = UUID(uuidString: nodeIdStr) else {
                    return .none
                }
                return .journey(nodeId: nodeId)

            case "log":
                guard let entryIdStr = userInfo["entryId"] as? String,
                      let entryId = UUID(uuidString: entryIdStr) else {
                    return .none
                }
                return .log(entryId: entryId)

            default:
                return .none
            }
        }
    }
}

// MARK: - Notification Names for Deep Link Navigation

public extension Notification.Name {
    static let ailoDeepLinkNavigation = Notification.Name("ailo.deeplink.navigation")
    static let navigateToLogEntry = Notification.Name("ailo.navigate.logEntry")
}
