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
            from: item.draft.from.email,
            to: item.draft.to.map { $0.email }.joined(separator: ", "),
            cc: item.draft.cc.map { $0.email }.joined(separator: ", "),
            bcc: item.draft.bcc.map { $0.email }.joined(separator: ", "),
            subject: item.draft.subject,
            textBody: item.draft.textBody,
            htmlBody: item.draft.htmlBody
        )
        try dao.enqueue(entity)
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
        let fromAddr = MailSendAddress(from)
        let toAddrs = to.split(separator: ",").map { MailSendAddress(String($0).trimmingCharacters(in: .whitespaces)) }
        let ccAddrs = cc.split(separator: ",").map { MailSendAddress(String($0).trimmingCharacters(in: .whitespaces)) }
        let bccAddrs = bcc.split(separator: ",").map { MailSendAddress(String($0).trimmingCharacters(in: .whitespaces)) }

        let draft = MailDraft(
            from: fromAddr,
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
}
