// OutboxDAOAdapter.swift
// Bridges MailOutboxDAO (DAOFactory) to OutboxDAO (MailSendService)

import Foundation

public class OutboxDAOAdapter: OutboxDAO {

    private let dao: MailOutboxDAO

    public init(_ dao: MailOutboxDAO) {
        self.dao = dao
    }

    public func enqueue(_ item: OutboxItem) throws {
        let entity = OutboxItemEntity(
            id: item.id,
            accountId: item.accountId,
            createdAt: item.createdAt,
            lastAttemptAt: item.lastAttemptAt,
            attempts: item.attempts,
            status: OutboxStatusEntity(rawValue: item.status.rawValue) ?? .pending,
            lastError: item.lastError,
            from: Self.formatAddress(item.draft.from),
            replyTo: item.draft.replyTo.map { Self.formatAddress($0) },
            to: item.draft.to.map { Self.formatAddress($0) }.joined(separator: ", "),
            cc: item.draft.cc.map { Self.formatAddress($0) }.joined(separator: ", "),
            bcc: item.draft.bcc.map { Self.formatAddress($0) }.joined(separator: ", "),
            subject: item.draft.subject,
            textBody: item.draft.textBody,
            htmlBody: item.draft.htmlBody
        )
        try dao.enqueue(entity)
    }

    /// Format address as "Name <email>" or just "email" if no name
    private static func formatAddress(_ addr: MailSendAddress) -> String {
        if let name = addr.name, !name.isEmpty {
            return "\(name) <\(addr.email)>"
        }
        return addr.email
    }

    /// Parse address from "Name <email>" or just "email" format
    private static func parseAddress(_ str: String) -> MailSendAddress {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        // Check for "Name <email>" format
        if let angleBracketStart = trimmed.lastIndex(of: "<"),
           let angleBracketEnd = trimmed.lastIndex(of: ">"),
           angleBracketStart < angleBracketEnd {
            let email = String(trimmed[trimmed.index(after: angleBracketStart)..<angleBracketEnd])
                .trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[..<angleBracketStart])
                .trimmingCharacters(in: .whitespaces)
            return MailSendAddress(email, name: name.isEmpty ? nil : name)
        }
        // Plain email
        return MailSendAddress(trimmed)
    }

    public func dequeueReady(accountId: UUID) throws -> OutboxItem? {
        guard let entity = try dao.dequeue(for: accountId) else { return nil }
        return entity.toOutboxItem()
    }

    public func markSending(_ id: UUID) throws {
        try dao.updateStatus(id, status: .sending, error: nil)
    }

    public func markSent(_ id: UUID, serverId: String?) throws {
        try dao.updateStatus(id, status: .sent, error: nil)
    }

    public func markFailed(_ id: UUID, error: String) throws {
        try dao.updateStatus(id, status: .failed, error: error)
        try dao.incrementAttempts(id)
    }

    public func markCancelled(_ id: UUID) throws {
        try dao.updateStatus(id, status: .cancelled, error: nil)
    }

    public func loadAll(accountId: UUID) throws -> [OutboxItem] {
        let pending = try dao.getPendingItems(for: accountId, limit: 1000)
        let failed = try dao.getFailedItems(for: accountId)
        return (pending + failed).map { $0.toOutboxItem() }
    }

    public func load(by id: UUID) throws -> OutboxItem? {
        // Nicht direkt verfügbar - nil zurückgeben
        return nil
    }

    public func retry(_ id: UUID) throws {
        try dao.updateStatus(id, status: .pending, error: nil)
    }
}

// MARK: - Entity Extension
extension OutboxItemEntity {
    func toOutboxItem() -> OutboxItem {
        let fromAddr = Self.parseAddress(from)
        let replyToAddr = replyTo.map { Self.parseAddress($0) }
        let toAddrs = Self.parseAddressList(to)
        let ccAddrs = Self.parseAddressList(cc)
        let bccAddrs = Self.parseAddressList(bcc)

        let draft = MailDraft(
            from: fromAddr,
            replyTo: replyToAddr,
            to: toAddrs,
            cc: ccAddrs,
            bcc: bccAddrs,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody
        )

        return OutboxItem(
            id: id,
            accountId: accountId,
            createdAt: createdAt,
            lastAttemptAt: lastAttemptAt,
            attempts: attempts,
            status: OutboxStatus(rawValue: status.rawValue) ?? .pending,
            lastError: lastError,
            draft: draft
        )
    }

    /// Parse comma-separated address list, handling "Name <email>" format
    private static func parseAddressList(_ str: String) -> [MailSendAddress] {
        guard !str.isEmpty else { return [] }
        // Split by comma, but be careful with commas inside names
        var addresses: [MailSendAddress] = []
        var current = ""
        var inAngleBracket = false

        for char in str {
            if char == "<" { inAngleBracket = true }
            else if char == ">" { inAngleBracket = false }

            if char == "," && !inAngleBracket {
                if !current.isEmpty {
                    addresses.append(parseAddress(current))
                }
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            addresses.append(parseAddress(current))
        }
        return addresses
    }

    /// Parse address from "Name <email>" or just "email" format
    private static func parseAddress(_ str: String) -> MailSendAddress {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        // Check for "Name <email>" format
        if let angleBracketStart = trimmed.lastIndex(of: "<"),
           let angleBracketEnd = trimmed.lastIndex(of: ">"),
           angleBracketStart < angleBracketEnd {
            let email = String(trimmed[trimmed.index(after: angleBracketStart)..<angleBracketEnd])
                .trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[..<angleBracketStart])
                .trimmingCharacters(in: .whitespaces)
            return MailSendAddress(email, name: name.isEmpty ? nil : name)
        }
        // Plain email
        return MailSendAddress(trimmed)
    }
}
