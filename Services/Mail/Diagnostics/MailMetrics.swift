// Provides lightweight telemetry for diagnostics and UI health indicators.

// AILO_APP/Configuration/Services/Mail/MailMetrics.swift
// Collects runtime metrics (connect time, fetch time, error counts) per account and host.
// Provides lightweight telemetry for diagnostics and UI health indicators.
// Thread-safety: updates are serialized via a private queue. Public API is lightweight.

import Foundation
import Combine

public final class MailMetrics {

    // MARK: Types

    public enum Step: String, CaseIterable, Sendable {
        case connect, login, list, select, search, fetch, parse, store, send
    }

    public enum ErrorKind: String, CaseIterable, Sendable {
        case dns, timeout, refused, unreachable, auth, protocolErr, parseErr, io, unknown
    }

    public enum Health: String, Sendable {
        case ok, degraded, down
    }

    public struct Summary: Sendable {
        public let accountId: UUID
        public let host: String
        public let lastUpdated: Date
        public let health: Health
        public let successCount: Int
        public let failureCount: Int
        public let recentErrorKinds: [ErrorKind: Int]
        public let avgDurationsMs: [Step: Double]
    }

    // Internal storage per (accountId, host)
    private struct Bucket {
        var lastUpdated: Date = Date()
        var successCount: Int = 0
        var failureCount: Int = 0
        var errorHistogram: [ErrorKind: Int] = [:]
        var emaDurations: [Step: Double] = [:]     // exponential moving average in milliseconds
        var emaAlpha: Double = 0.3                 // smoothing factor
        var lastErrorAt: Date? = nil
        var lastSuccessAt: Date? = nil
        var lastHealth: Health = .ok
        var consecutiveFailures: Int = 0
        var consecutiveSuccess: Int = 0
    }

    // MARK: Singleton

    public static let shared = MailMetrics()
    private init() {}

    // MARK: Storage

    private let q = DispatchQueue(label: "mail.metrics.queue")
    private var buckets: [Key: Bucket] = [:]

    // Health publishers per account
    private var subjects: [UUID: PassthroughSubject<Health, Never>] = [:]

    // MARK: Key

    private struct Key: Hashable {
        let accountId: UUID
        let host: String
    }

    // MARK: Public API

    /// Observe a duration for a given step. Duration is provided in seconds.
    public func observe(step: Step, duration seconds: TimeInterval, accountId: UUID, host: String) {
        q.sync {
            var b = buckets[Key(accountId: accountId, host: host)] ?? Bucket()
            let ms = max(0.0, seconds * 1000.0)
            let prev = b.emaDurations[step] ?? ms
            b.emaDurations[step] = b.emaAlpha * ms + (1.0 - b.emaAlpha) * prev
            b.lastUpdated = Date()
            buckets[Key(accountId: accountId, host: host)] = b
        }
    }

    public func markSuccess(step: Step, accountId: UUID, host: String) {
        updateHealth(accountId: accountId, host: host, success: true, errorKind: nil)
    }

    public func markFailure(step: Step, accountId: UUID, host: String, errorKind: ErrorKind) {
        updateHealth(accountId: accountId, host: host, success: false, errorKind: errorKind)
    }

    public func summary(accountId: UUID, host: String) -> Summary {
        return q.sync {
            let key = Key(accountId: accountId, host: host)
            let b = buckets[key] ?? Bucket()
            return Summary(
                accountId: accountId,
                host: host,
                lastUpdated: b.lastUpdated,
                health: b.lastHealth,
                successCount: b.successCount,
                failureCount: b.failureCount,
                recentErrorKinds: b.errorHistogram,
                avgDurationsMs: b.emaDurations
            )
        }
    }

    /// Publisher that emits health changes for the given account.
    public func publisherHealth(accountId: UUID) -> AnyPublisher<Health, Never> {
        q.sync {
            let subj = subjects[accountId] ?? {
                let s = PassthroughSubject<Health, Never>()
                subjects[accountId] = s
                return s
            }()
            return subj.eraseToAnyPublisher()
        }
    }

    // MARK: Internals

    private func updateHealth(accountId: UUID, host: String, success: Bool, errorKind: ErrorKind?) {
        q.sync {
            let key = Key(accountId: accountId, host: host)
            var b = buckets[key] ?? Bucket()
            b.lastUpdated = Date()
            if success {
                b.successCount &+= 1
                b.consecutiveSuccess &+= 1
                b.consecutiveFailures = 0
                b.lastSuccessAt = b.lastUpdated
            } else {
                b.failureCount &+= 1
                b.consecutiveFailures &+= 1
                b.consecutiveSuccess = 0
                if let ek = errorKind {
                    b.errorHistogram[ek] = (b.errorHistogram[ek] ?? 0) + 1
                }
                b.lastErrorAt = b.lastUpdated
            }

            // Simple health heuristic:
            // - DOWN: >= 3 consecutive failures in the last ~N minutes
            // - DEGRADED: 1-2 consecutive failures OR EMA connect/fetch durations over soft thresholds
            // - OK: otherwise
            let prevHealth = b.lastHealth
            let newHealth: Health
            if b.consecutiveFailures >= 3 {
                newHealth = .down
            } else if b.consecutiveFailures >= 1 {
                newHealth = .degraded
            } else {
                // check latency soft thresholds (ms)
                let connect = b.emaDurations[.connect] ?? 0
                let fetch = b.emaDurations[.fetch] ?? 0
                if connect > 2_500 || fetch > 3_000 {
                    newHealth = .degraded
                } else {
                    newHealth = .ok
                }
            }
            b.lastHealth = newHealth
            buckets[key] = b

            if newHealth != prevHealth {
                // emit per-account health only (aggregate across hosts if needed by UI)
                if let subj = subjects[accountId] {
                    subj.send(newHealth)
                } else {
                    let s = PassthroughSubject<Health, Never>()
                    subjects[accountId] = s
                    s.send(newHealth)
                }
            }
        }
    }

    // MARK: Mapping helpers

    public func mapNWErrorToKind(_ error: Error) -> ErrorKind {
        // Keep this tolerant; do not depend on Network types at compile time here.
        let s = String(describing: error).lowercased()
        if s.contains("dns") { return .dns }
        if s.contains("timed out") || s.contains("timeout") { return .timeout }
        if s.contains("refused") { return .refused }
        if s.contains("unreach") { return .unreachable }
        if s.contains("auth") { return .auth }
        if s.contains("parse") { return .parseErr }
        if s.contains("protocol") { return .protocolErr }
        if s.contains("read") || s.contains("write") || s.contains("io") { return .io }
        return .unknown
    }
}
