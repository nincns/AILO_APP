// AILO_APP/Configuration/Services/Mail/MailSendService.swift
// Manages the outbound mail queue (Outbox).
// Uses SMTPClient to deliver messages asynchronously with retry and error persistence.
// Integrates with MailDAO for local outbox storage.

import Foundation
import Combine

// MARK: - Local Types (resolve ambiguity)

public struct MailSendAddress: Sendable, Hashable {
    public let email: String
    public let name: String?

    public init(_ email: String, name: String? = nil) {
        self.email = email
        self.name = name
    }
}

/// Attachment for outgoing emails
public struct MailSendAttachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct MailSendMessage: Sendable {
    public let from: MailSendAddress
    public let to: [MailSendAddress]
    public let cc: [MailSendAddress]
    public let bcc: [MailSendAddress]
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [MailSendAttachment]

    public init(from: MailSendAddress,
                to: [MailSendAddress],
                cc: [MailSendAddress] = [],
                bcc: [MailSendAddress] = [],
                subject: String,
                textBody: String? = nil,
                htmlBody: String? = nil,
                attachments: [MailSendAttachment] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
    }
}

public enum SendValidationError: LocalizedError {
    case missingSender
    case noRecipients
    case emptyBody
    case invalidAddress(String)

    public var errorDescription: String? {
        switch self {
        case .missingSender: return String(localized: "Absender fehlt.")
        case .noRecipients: return String(localized: "Keine Empfänger angegeben.")
        case .emptyBody: return String(localized: "Die Nachricht hat keinen Inhalt.")
        case .invalidAddress(let addr): return String(localized: "Ungültige E‑Mail‑Adresse: \(addr)")
        }
    }
}

// MARK: - Outbox Models

public enum OutboxStatus: String, Sendable {
    case pending
    case sending
    case sent
    case failed
    case cancelled
}

public struct OutboxItem: Sendable, Identifiable {
    public let id: UUID
    public let accountId: UUID
    public let createdAt: Date
    public var lastAttemptAt: Date?
    public var attempts: Int
    public var status: OutboxStatus
    public var lastError: String?
    public let draft: MailDraft

    public init(id: UUID = UUID(),
                accountId: UUID,
                createdAt: Date = Date(),
                lastAttemptAt: Date? = nil,
                attempts: Int = 0,
                status: OutboxStatus = .pending,
                lastError: String? = nil,
                draft: MailDraft) {
        self.id = id
        self.accountId = accountId
        self.createdAt = createdAt
        self.lastAttemptAt = lastAttemptAt
        self.attempts = attempts
        self.status = status
        self.lastError = lastError
        self.draft = draft
    }
}

public struct MailDraft: Sendable {
    public let from: MailSendAddress
    public let to: [MailSendAddress]
    public let cc: [MailSendAddress]
    public let bcc: [MailSendAddress]
    public let subject: String
    public let textBody: String?
    public let htmlBody: String?
    public let attachments: [MailSendAttachment]

    public init(from: MailSendAddress,
                to: [MailSendAddress],
                cc: [MailSendAddress] = [],
                bcc: [MailSendAddress] = [],
                subject: String,
                textBody: String? = nil,
                htmlBody: String? = nil,
                attachments: [MailSendAttachment] = []) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
    }

    public func toMailMessage() -> MailSendMessage {
        MailSendMessage(
            from: from,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            textBody: textBody,
            htmlBody: htmlBody,
            attachments: attachments
        )
    }
}

// MARK: - DAO abstraction (to be implemented in Core/Storage/MailDAO.swift)

public protocol OutboxDAO {
    func enqueue(_ item: OutboxItem) throws
    func dequeueReady(accountId: UUID) throws -> OutboxItem?       // returns next pending item
    func markSending(_ id: UUID) throws
    func markSent(_ id: UUID, serverId: String?) throws
    func markFailed(_ id: UUID, error: String) throws
    func markCancelled(_ id: UUID) throws
    func loadAll(accountId: UUID) throws -> [OutboxItem]
    func load(by id: UUID) throws -> OutboxItem?
    func retry(_ id: UUID) throws                                   // set status back to pending, attempts unchanged
}

// MARK: - MailSendService

public final class MailSendService {

    public static let shared = MailSendService()
    private init() {}

    // Dependencies
    public var smtpFactory: (() -> (any SMTPClientProtocol))?          // injected
    public var smtpConfigProvider: ((UUID) -> SMTPConfig?)?   // by accountId (returns nil if not found)
    public var retryPolicy: RetryPolicy = .shared
    public var logger: MailLogger = .shared
    public var metrics: MailMetrics = .shared
    public var dao: OutboxDAO?

    // Per-account worker queues
    private let stateQ = DispatchQueue(label: "mail.send.service.state")
    private var workers: [UUID: DispatchQueue] = [:]
    private var cancelTokens: [UUID: CancellationToken] = [:]

    // Outbox publishers per account
    private var outboxSubjects: [UUID: CurrentValueSubject<[OutboxItem], Never>] = [:]

    // MARK: Public API

    /// Adds a draft to the outbox and schedules the worker.
    @discardableResult
    public func queue(_ draft: MailDraft, accountId: UUID) -> UUID {
        let item = OutboxItem(accountId: accountId, draft: draft)
        do {
            try dao?.enqueue(item)
            publish(accountId)
            ensureWorker(accountId)
            return item.id
        } catch {
            logger.error(.SEND, accountId: accountId, "enqueue failed: \(error)")
            return item.id
        }
    }

    /// Retry a specific outbox item (set back to pending). Worker will pick it up.
    public func retry(_ id: UUID, accountId: UUID) {
        do {
            try dao?.retry(id)
            publish(accountId)
            ensureWorker(accountId)
        } catch {
            logger.error(.SEND, accountId: accountId, "retry failed: \(error)")
        }
    }

    /// Process at most the next item (if any).
    public func processNext(accountId: UUID) {
        ensureWorker(accountId, oneShot: true)
    }

    /// Process the whole queue (until empty or failure with backoff).
    public func processAll(accountId: UUID) {
        ensureWorker(accountId)
    }

    /// Observe outbox changes for an account.
    public func publisherOutbox(accountId: UUID) -> AnyPublisher<[OutboxItem], Never> {
        stateQ.sync {
            let subj = outboxSubjects[accountId] ?? {
                let items: [OutboxItem]
                do {
                    items = try dao?.loadAll(accountId: accountId) ?? []
                } catch {
                    items = []
                }
                let s = CurrentValueSubject<[OutboxItem], Never>(items)
                outboxSubjects[accountId] = s
                return s
            }()
            return subj.eraseToAnyPublisher()
        }
    }

    // MARK: - Phase 2: High-level send API

    /// Validate, enqueue, and trigger processing for a draft.
    public func sendDraft(_ draft: MailDraft, accountId: UUID) async throws {
        try validateDraft(draft)
        guard let dao = dao else { throw SendValidationError.missingSender } // treat missing DAO as configuration error
        let item = OutboxItem(accountId: accountId, draft: draft)
        try dao.enqueue(item)
        publish(accountId)
        ensureWorker(accountId)
        logger.info(.SEND, accountId: accountId, "Draft queued: \(item.id.uuidString.prefix(8))")
    }

    /// Process the outbox until empty (best-effort). Returns when no pending/sending items remain or after a soft cap.
    public func processOutbox(accountId: UUID) async {
        // Kick the worker and then poll the DAO until the queue stabilizes.
        ensureWorker(accountId)
        // Soft cap: 60s of waiting in 0.5s steps
        let capNs: UInt64 = 60 * 1_000_000_000
        let stepNs: UInt64 = 500_000_000
        var waited: UInt64 = 0
        while waited < capNs {
            let items: [OutboxItem] = (try? dao?.loadAll(accountId: accountId)) ?? []
            let active = items.contains { $0.status == .pending || $0.status == .sending }
            if !active { break }
            try? await Task.sleep(nanoseconds: stepNs)
            waited &+= stepNs
        }
    }

    /// Retry a failed outbox item by setting it back to pending and waking the worker.
    public func retryFailed(item: OutboxItem) async throws {
        guard let dao = dao else { return }
        try dao.retry(item.id)
        publish(item.accountId)
        ensureWorker(item.accountId)
        logger.info(.SEND, accountId: item.accountId, "Retry scheduled for \(item.id.uuidString.prefix(8))")
    }

    /// Trigger a sync of the Sent folder so the just-sent message appears in the local store.
    /// Many servers auto-place a copy in Sent; this kicks the sync engine to pull it.
    public func moveDraftToSent(draft: MailDraft, accountId: UUID) async throws {
        let sentFolder = sentFolderName(accountId: accountId)
        guard !sentFolder.isEmpty else { return }
        
        // TODO: Implement sent folder sync trigger without MailSyncEngine dependency
        // This could use the MailRepository to trigger a sync of just the Sent folder
        
        logger.debug(.SEND, accountId: accountId, "Sent folder sync requested: \(sentFolder)")
    }

    // MARK: - Validation & helpers

    private func validateDraft(_ draft: MailDraft) throws {
        // Sender
        if draft.from.email.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            throw SendValidationError.missingSender
        }
        // Recipients
        let recipients = draft.to + draft.cc + draft.bcc
        if recipients.isEmpty { throw SendValidationError.noRecipients }
        for addr in recipients.map({ $0.email }) {
            if !isPlausibleEmail(addr) { throw SendValidationError.invalidAddress(addr) }
        }
        // Body (require at least one of text/html non-empty)
        let hasText = (draft.textBody?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty == false)
        let hasHTML = (draft.htmlBody?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty == false)
        if !hasText && !hasHTML { throw SendValidationError.emptyBody }
    }

    private func isPlausibleEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        // Minimal plausibility: contains one '@' and a dot in the domain part
        guard let at = t.firstIndex(of: "@") else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".")
    }

    private func sentFolderName(accountId: UUID) -> String {
        // Prefer persisted account config's Sent mapping; fallback to "Sent".
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let acc = list.first(where: { $0.id == accountId }) else { return "Sent" }
        let name = acc.folders.sent
        return name.isEmpty ? "Sent" : name
    }

    // MARK: Worker orchestration

    private func ensureWorker(_ accountId: UUID, oneShot: Bool = false) {
        let queue = stateQ.sync { () -> DispatchQueue in
            if let q = workers[accountId] { return q }
            let nq = DispatchQueue(label: "mail.send.service.\(accountId.uuidString)")
            workers[accountId] = nq
            return nq
        }
        // Spawn or poke worker
        let token: CancellationToken = stateQ.sync { () -> CancellationToken in
            if let existing = cancelTokens[accountId] {
                return existing
            }
            let t = CancellationToken()
            cancelTokens[accountId] = t
            return t
        }
        queue.async { [weak self] in
            Task {
                await self?.workerLoop(accountId: accountId, token: token, oneShot: oneShot)
            }
        }
    }

    private func workerLoop(accountId: UUID, token: CancellationToken, oneShot: Bool) async {
        var attempt = 1
        while !token.isCancelled {
            guard let dao = dao else { return }
            guard let item = try? dao.dequeueReady(accountId: accountId) else {
                // nothing left
                if oneShot { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            // mark as sending
            try? dao.markSending(item.id)
            publish(accountId)

            let smtp: any SMTPClientProtocol = smtpFactory?() ?? SMTPClient()
            print("📤 [SEND] Using SMTP client: \(type(of: smtp))")

            guard let cfg = (smtpConfigProvider?(accountId) ?? Self.defaultSMTPConfig(for: accountId)) else {
                logger.error(.SEND, accountId: accountId, "No SMTP config")
                try? dao.markFailed(item.id, error: "No SMTP config")
                publish(accountId)
                continue
            }
            print("📤 [SEND] Config: \(cfg.host):\(cfg.port) encryption:\(cfg.encryption)")

            let start = Date()
            let result = await runSend(item: item, smtp: smtp, config: cfg)
            print("📤 [SEND] Result: \(result)")
            let duration = Date().timeIntervalSince(start)
            metrics.observe(step: .send, duration: duration, accountId: accountId, host: cfg.host)

            switch result {
            case .success(let serverId):
                try? dao.markSent(item.id, serverId: serverId)
                retryPolicy.recordSuccess(RetryPolicy.Key(accountId: accountId, host: cfg.host))
                metrics.markSuccess(step: .send, accountId: accountId, host: cfg.host)
                logger.info(.SEND, accountId: accountId, "Sent \(item.id.uuidString.prefix(8)) ✅")
                publish(accountId)
                attempt = 1
                if oneShot { break }
            case .failed(let err):
                // Map to retry/backoff categories
                let kind = metrics.mapNWErrorToKind(err)
                retryPolicy.recordFailure(RetryPolicy.Key(accountId: accountId, host: cfg.host), kind: mapToRetryKind(kind))
                metrics.markFailure(step: .send, accountId: accountId, host: cfg.host, errorKind: kind)
                logger.warn(.SEND, accountId: accountId, "Send failed (\(String(describing: err))) – attempt \(attempt)")

                try? dao.markFailed(item.id, error: err.localizedDescription)
                publish(accountId)

                // Backoff and continue with the next/again
                var delay: TimeInterval = retryPolicy.nextDelay(for: mapToRetryKind(kind), attempt: attempt, key: RetryPolicy.Key(accountId: accountId, host: cfg.host))
                // Minimum 30 Sekunden Backoff bei Protokoll-/Verbindungsfehlern
                if delay < 30 {
                    delay = 30
                }
                attempt &+= 1
                logger.info(.SEND, accountId: accountId, "Backoff \(Int(delay))s before next attempt")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if oneShot { break }
            }
        }
    }

    private func runSend(item: OutboxItem, smtp: any SMTPClientProtocol, config: SMTPConfig) async -> DeliveryResult {
        let msg = item.draft.toMailMessage()
        let adapted = MailMessage(
            from: MailAddress(msg.from.email, name: msg.from.name),
            to: msg.to.map { MailAddress($0.email, name: $0.name) },
            cc: msg.cc.map { MailAddress($0.email, name: $0.name) },
            bcc: msg.bcc.map { MailAddress($0.email, name: $0.name) },
            subject: msg.subject,
            textBody: msg.textBody,
            htmlBody: msg.htmlBody,
            attachments: msg.attachments.map { MailAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) },
            signingCertificateId: signingCertificateId(for: item.accountId)
        )
        return await smtp.send(adapted, using: config)
    }

    /// Returns the signing certificate ID if signing is enabled for the account
    private func signingCertificateId(for accountId: UUID) -> String? {
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let acc = list.first(where: { $0.id == accountId }),
              acc.signingEnabled,
              let certId = acc.signingCertificateId,
              !certId.isEmpty else { return nil }
        return certId
    }

    // MARK: Publishing

    private func publish(_ accountId: UUID) {
        let items: [OutboxItem]
        do {
            items = try dao?.loadAll(accountId: accountId) ?? []
        } catch {
            items = []
        }
        stateQ.sync {
            if let subj = outboxSubjects[accountId] {
                subj.send(items)
            } else {
                let s = CurrentValueSubject<[OutboxItem], Never>(items)
                outboxSubjects[accountId] = s
                s.send(items)
            }
        }
    }

    // MARK: Mapping helpers

    private func mapToRetryKind(_ kind: MailMetrics.ErrorKind) -> RetryPolicy.ErrorKind {
        switch kind {
        case .dns: return .dns
        case .timeout: return .timeout
        case .refused: return .refused
        case .unreachable: return .unreachable
        case .auth: return .auth
        case .protocolErr: return .protocolErr
        case .parseErr: return .parseErr
        case .io: return .io
        case .unknown: return .unknown
        }
    }

    // MARK: Default SMTP config fallback (reads from persisted accounts)
    private static func defaultSMTPConfig(for accountId: UUID) -> SMTPConfig? {
        guard let data = UserDefaults.standard.data(forKey: "mail.accounts"),
              let list = try? JSONDecoder().decode([MailAccountConfig].self, from: data),
              let acc = list.first(where: { $0.id == accountId }) else { return nil }
        let enc: SMTPTLSEncryption
        switch acc.smtpEncryption {
        case .none: enc = .plain
        case .sslTLS: enc = .sslTLS
        case .startTLS: enc = .startTLS
        }
        return SMTPConfig(
            host: acc.smtpHost,
            port: acc.smtpPort,
            encryption: enc,
            heloName: nil,
            username: acc.smtpUsername.isEmpty ? nil : acc.smtpUsername,
            password: acc.smtpPassword,
            connectionTimeoutSec: acc.connectionTimeoutSec,
            commandTimeoutSec: max(5, acc.connectionTimeoutSec/2),
            sniHost: acc.smtpHost
        )
    }

    // MARK: Small async bridge
}

