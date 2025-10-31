// AILO_APP/Core/Storage/MailEntities.swift
// DEPRECATED: Use MailSchema.swift instead
// File obsolete as of Phase 1 refactoring - keeping for reference only

#if false
// Entity models for mail data storage layer.
// These models represent the structure of data as stored in the database.

import Foundation

// MARK: - Header Entity

public struct MessageHeaderEntity: Sendable {
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public let from: String
    public let subject: String
    public let date: Date?
    public let flags: [String]

    public init(accountId: UUID, folder: String, uid: String, from: String, subject: String, date: Date?, flags: [String]) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.from = from
        self.subject = subject
        self.date = date
        self.flags = flags
    }
}

// MARK: - Body Entity

public struct MessageBodyEntity: Sendable {
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public let text: String?
    public let html: String?
    public let hasAttachments: Bool

    public init(accountId: UUID, folder: String, uid: String, text: String?, html: String?, hasAttachments: Bool) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.text = text
        self.html = html
        self.hasAttachments = hasAttachments
    }
}

// MARK: - Attachment Entity

public struct AttachmentEntity: Sendable {
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public let partId: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let data: Data?

    public init(accountId: UUID, folder: String, uid: String, partId: String, filename: String, mimeType: String, sizeBytes: Int, data: Data?) {
        self.accountId = accountId
        self.folder = folder
        self.uid = uid
        self.partId = partId
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.data = data
    }
}
#endif // Disabled duplicates; prefer MailSchema.swift definitions
