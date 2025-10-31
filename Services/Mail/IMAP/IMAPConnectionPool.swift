// AILO_APP/Configuration/Services/Mail/IMAPConnectionPool.swift
// Lightweight connection pool for IMAP sessions (per account).
// Goal: Reuse open connections across short-lived sync steps to reduce connect/login overhead.
// NOTE: Keep semantics simple for MVP. Ensure callers recreate connections if account host/port/TLS changes.

import Foundation

public final actor IMAPConnectionPool {
    public static let shared = IMAPConnectionPool()
    private var pool: [UUID: IMAPConnection] = [:]

    public init() {}

    /// Acquire an IMAPConnection for an account. Reuses an open one if present; otherwise opens a new connection.
    /// - Parameters:
    ///   - accountId: The account identifier.
    ///   - config: The connection configuration (host/port/tls/etc.). If a pooled connection exists but is closed, a new one is opened using this config.
    ///   - labelSuffix: Optional suffix to help identify the connection in logs.
    /// - Returns: A ready IMAPConnection instance.
    @discardableResult
    public func acquire(accountId: UUID, config: IMAPConnectionConfig, labelSuffix: String? = nil) async throws -> IMAPConnection {
        if let existing = pool[accountId], existing.isOpen {
            return existing
        }
        let labelCore = String(accountId.uuidString.prefix(6))
        let label = "pooled.\(labelCore)" + (labelSuffix.map { ".\($0)" } ?? "")
        let conn = IMAPConnection(label: label)
        try await conn.open(config)
        pool[accountId] = conn
        return conn
    }

    /// Release the pooled connection for an account.
    /// - Parameter close: If true (default), the connection is also closed.
    public func release(accountId: UUID, close: Bool = true) {
        if close { pool[accountId]?.close() }
        pool[accountId] = nil
    }

    /// Close and clear all pooled connections.
    public func invalidateAll() {
        for (_, c) in pool { c.close() }
        pool.removeAll()
    }
}
