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

// MARK: - Mail Attachment Model

public struct MailAttachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Mail Message Model

public struct MailMessage: Sendable {
    public let from: MailAddress
    public let to: [MailAddress]
    public let cc: [MailAddress]
    public let bcc: [MailAddress]
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [MailAttachment]
    public let signingCertificateId: String?  // S/MIME signing certificate reference

    public init(from: MailAddress,
                to: [MailAddress],
                cc: [MailAddress] = [],
                bcc: [MailAddress] = [],
                subject: String,
                textBody: String? = nil,
                htmlBody: String? = nil,
                attachments: [MailAttachment] = [],
                signingCertificateId: String? = nil) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.signingCertificateId = signingCertificateId
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
    public var emailAddress: String
    public var replyTo: String?

    // S/MIME Signing
    public var signingEnabled: Bool
    public var signingCertificateId: String?

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

    // Sync Limits
    public var syncLimitInitial: Int
    public var syncLimitRefresh: Int
    public var syncLimitIncremental: Int

    public init(
        id: UUID = UUID(),
        accountName: String,
        displayName: String? = nil,
        emailAddress: String,
        replyTo: String? = nil,
        signingEnabled: Bool = false,
        signingCertificateId: String? = nil,
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
        folders: Folders = Folders(),
        syncLimitInitial: Int = 200,
        syncLimitRefresh: Int = 500,
        syncLimitIncremental: Int = 50
    ) {
        self.id = id
        self.accountName = accountName
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.replyTo = replyTo
        self.signingEnabled = signingEnabled
        self.signingCertificateId = signingCertificateId
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
        self.syncLimitInitial = syncLimitInitial
        self.syncLimitRefresh = syncLimitRefresh
        self.syncLimitIncremental = syncLimitIncremental
    }

    // MARK: - Codable Migration (für bestehende Accounts ohne neue Felder)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        accountName = try container.decode(String.self, forKey: .accountName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        emailAddress = try container.decode(String.self, forKey: .emailAddress)
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        signingEnabled = try container.decodeIfPresent(Bool.self, forKey: .signingEnabled) ?? false
        signingCertificateId = try container.decodeIfPresent(String.self, forKey: .signingCertificateId)
        recvProtocol = try container.decode(MailProtocol.self, forKey: .recvProtocol)
        recvHost = try container.decode(String.self, forKey: .recvHost)
        recvPort = try container.decode(Int.self, forKey: .recvPort)
        recvEncryption = try container.decode(MailEncryption.self, forKey: .recvEncryption)
        recvUsername = try container.decode(String.self, forKey: .recvUsername)
        recvPassword = try container.decodeIfPresent(String.self, forKey: .recvPassword)
        smtpHost = try container.decode(String.self, forKey: .smtpHost)
        smtpPort = try container.decode(Int.self, forKey: .smtpPort)
        smtpEncryption = try container.decode(MailEncryption.self, forKey: .smtpEncryption)
        smtpUsername = try container.decode(String.self, forKey: .smtpUsername)
        smtpPassword = try container.decodeIfPresent(String.self, forKey: .smtpPassword)
        authMethod = try container.decode(MailAuthMethod.self, forKey: .authMethod)
        oauthToken = try container.decodeIfPresent(String.self, forKey: .oauthToken)
        connectionTimeoutSec = try container.decodeIfPresent(Int.self, forKey: .connectionTimeoutSec) ?? 15
        enableLogging = try container.decodeIfPresent(Bool.self, forKey: .enableLogging) ?? false
        checkIntervalMin = try container.decodeIfPresent(Int.self, forKey: .checkIntervalMin)
        checkIntervalEnabled = try container.decodeIfPresent(Bool.self, forKey: .checkIntervalEnabled) ?? false
        folders = try container.decodeIfPresent(Folders.self, forKey: .folders) ?? Folders()

        // Neue Sync-Limit Felder mit Defaults für Migration
        syncLimitInitial = try container.decodeIfPresent(Int.self, forKey: .syncLimitInitial) ?? 200
        syncLimitRefresh = try container.decodeIfPresent(Int.self, forKey: .syncLimitRefresh) ?? 500
        syncLimitIncremental = try container.decodeIfPresent(Int.self, forKey: .syncLimitIncremental) ?? 50
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountName, displayName, emailAddress, replyTo
        case signingEnabled, signingCertificateId
        case recvProtocol, recvHost, recvPort, recvEncryption, recvUsername, recvPassword
        case smtpHost, smtpPort, smtpEncryption, smtpUsername, smtpPassword
        case authMethod, oauthToken, connectionTimeoutSec, enableLogging
        case checkIntervalMin, checkIntervalEnabled, folders
        case syncLimitInitial, syncLimitRefresh, syncLimitIncremental
    }
}
