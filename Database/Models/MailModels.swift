import Foundation

// MARK: - Core mail model enums

// MARK: - Mail Address Model

public struct MailAddress: Sendable, Hashable {
    public let email: String
    public let name: String?

    public init(_ email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }
}

// MARK: - Mail Message Model

public struct MailMessage: Sendable {
    public let from: MailAddress
    public let replyTo: MailAddress?
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let bcc: [MailAddress]
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?

    public init(from: MailAddress,
                replyTo: MailAddress? = nil,
                to: [MailAddress],
                cc: [MailAddress] = [],
                bcc: [MailAddress] = [],
                subject: String,
                textBody: String? = nil,
                htmlBody: String? = nil) {
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
    }
}

public enum MailProtocol: String, Codable, CaseIterable, Sendable {
    case imap
    case pop3
}

public enum MailEncryption: String, Codable, CaseIterable, Sendable {
    case none
    case sslTLS
    case startTLS
}

public enum MailAuthMethod: String, Codable, CaseIterable, Sendable {
    case password
    case oauth2
    case appPassword
}

// MARK: - Account configuration

public struct MailAccountConfig: Codable, Identifiable, Equatable, Sendable {

    /// Special-use folder mapping for this account.
    public struct Folders: Codable, Equatable, Sendable {
        public var inbox: String
        public var sent: String
        public var drafts: String
        public var trash: String
        public var spam: String

        public init(inbox: String = "INBOX",
                    sent: String = "Sent",
                    drafts: String = "Drafts",
                    trash: String = "Trash",
                    spam: String = "Spam") {
            self.inbox = inbox
            self.sent = sent
            self.drafts = drafts
            self.trash = trash
            self.spam = spam
        }
    }

    // Keep properties in a consistent order for readability and JSON stability
    public var id: UUID
    public var accountName: String
    public var displayName: String?
    public var replyTo: String?

    public var recvProtocol: MailProtocol
    public var recvHost: String
    public var recvPort: Int
    public var recvEncryption: MailEncryption
    public var recvUsername: String
    public var recvPassword: String?

    public var smtpHost: String
    public var smtpPort: Int
    public var smtpEncryption: MailEncryption
    public var smtpUsername: String
    public var smtpPassword: String?

    public var authMethod: MailAuthMethod
    public var oauthToken: String?

    public var connectionTimeoutSec: Int
    public var enableLogging: Bool

    /// Interval in minutes. Only used if `checkIntervalEnabled` is true.
    public var checkIntervalMin: Int?
    public var checkIntervalEnabled: Bool

    public var folders: Folders

    public init(
        id: UUID = UUID(),
        accountName: String,
        displayName: String? = nil,
        replyTo: String? = nil,
        recvProtocol: MailProtocol,
        recvHost: String,
        recvPort: Int,
        recvEncryption: MailEncryption,
        recvUsername: String,
        recvPassword: String? = nil,
        smtpHost: String,
        smtpPort: Int,
        smtpEncryption: MailEncryption,
        smtpUsername: String,
        smtpPassword: String? = nil,
        authMethod: MailAuthMethod,
        oauthToken: String? = nil,
        connectionTimeoutSec: Int = 15,
        enableLogging: Bool = false,
        checkIntervalMin: Int? = nil,
        checkIntervalEnabled: Bool = false,
        folders: Folders = Folders()
    ) {
        self.id = id
        self.accountName = accountName
        self.displayName = displayName
        self.replyTo = replyTo
        self.recvProtocol = recvProtocol
        self.recvHost = recvHost
        self.recvPort = recvPort
        self.recvEncryption = recvEncryption
        self.recvUsername = recvUsername
        self.recvPassword = recvPassword
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpEncryption = smtpEncryption
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.authMethod = authMethod
        self.oauthToken = oauthToken
        self.connectionTimeoutSec = connectionTimeoutSec
        self.enableLogging = enableLogging
        self.checkIntervalMin = checkIntervalMin
        self.checkIntervalEnabled = checkIntervalEnabled
        self.folders = folders
    }
}
