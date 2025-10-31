// AILO_APP/Configuration/Services/Mail/MailHealthMonitor.swift
// Observes per-account connection health and aggregates metrics for diagnostics.
// Publishes account status (OK / Degraded / Down) for UI display in DashboardView.

// AILO_APP/Configuration/Services/Mail/Diagnostics/MailHealthMonitor.swift
// Aggregated account health monitor.
// Consumes MailMetrics + MailSyncEngine (and optional RetryPolicy) to compute a concise OK/Degraded/Down state.
// Exposes a publisher per account for Dashboard/Config screens.

import Foundation
import Combine

public final class MailHealthMonitor {

    // MARK: Types

    public enum Health: String, Sendable {
        case ok, degraded, down
    }

    public struct Snapshot: Sendable {
        public let accountId: UUID
        public let health: Health
        public let lastSuccessAt: Date?
        public let lastErrorAt: Date?
        public let consecutiveFailures: Int
        public let circuitOpen: Bool
        public let latencyEMAms: [MailMetrics.Step: Double]
        public let uptimePercent: Double
        public let errorRate: Double
        public let updatedAt: Date
    }

    // MARK: Singleton

    public static let shared = MailHealthMonitor()
    private init() {}

    // MARK: Dependencies

    private var metrics: MailMetrics = .shared
    private var engine: Any = ()  // Will be set in attach()
    private var retry: RetryPolicy = .shared

    // MARK: State

    private let q = DispatchQueue(label: "mail.health.monitor.state")
    private var snaps: [UUID: Snapshot] = [:]
    private var subjects: [UUID: CurrentValueSubject<Health, Never>] = [:]
    private var bag = Set<AnyCancellable>()

    // Snapshot publishers per account
    private var snapshotSubjects: [UUID: CurrentValueSubject<Snapshot, Never>] = [:]

    // Uptime tracking per account (coarse): accumulate time in OK state since windowStart
    private struct UptimeBucket { var windowStart: Date; var okAccum: TimeInterval; var lastHealth: Health; var lastChange: Date }
    private var uptime: [UUID: UptimeBucket] = [:]

    // Optional mapping for retry keys (account → host), if engine config is used there.
    public var hostProvider: ((UUID) -> String)? = nil

    // MARK: Attach

    /// Wire the monitor to engine + metrics streams. Call this once during app setup.
    public func attach(engine: Any,
                       metrics: MailMetrics = .shared,
                       retryPolicy: RetryPolicy = .shared) {
        self.engine = engine
        self.metrics = metrics
        self.retry = retryPolicy

        // Observe sync state changes and recompute health
        // We don't know all account IDs upfront; subscribe lazily by exposing a method to ensure a subject exists.
        // The repository/composition root should call `ensureAccount(id:)` when an account becomes visible.
    }

    /// Ensure internal structures exist for an account and set an initial value.
    public func ensureAccount(_ accountId: UUID) {
        q.sync {
            if subjects[accountId] == nil {
                subjects[accountId] = CurrentValueSubject<Health, Never>(.ok)
            }
            if snaps[accountId] == nil {
                snaps[accountId] = Snapshot(
                    accountId: accountId,
                    health: .ok,
                    lastSuccessAt: nil,
                    lastErrorAt: nil,
                    consecutiveFailures: 0,
                    circuitOpen: false,
                    latencyEMAms: [:],
                    uptimePercent: 1.0,
                    errorRate: 0.0,
                    updatedAt: Date()
                )
            }

            if self.snapshotSubjects[accountId] == nil {
                let snap = Snapshot(accountId: accountId, health: .ok, lastSuccessAt: nil, lastErrorAt: nil, consecutiveFailures: 0, circuitOpen: false, latencyEMAms: [:], uptimePercent: 1.0, errorRate: 0.0, updatedAt: Date())
                self.snapshotSubjects[accountId] = CurrentValueSubject<Snapshot, Never>(snap)
                self.snaps[accountId] = snap
            }
            if self.uptime[accountId] == nil {
                self.uptime[accountId] = UptimeBucket(windowStart: Date(), okAccum: 0, lastHealth: .ok, lastChange: Date())
            }
        }

        // Hook health publisher from MailMetrics to keep latency-based signals
        metrics.publisherHealth(accountId: accountId)
            .receive(on: q)
            .sink { [weak self] (health: MailMetrics.Health) in
                self?.recompute(accountId)
            }
            .store(in: &bag)

        // Hook sync engine phase changes as activity signals
        if let syncEngine = engine as? Any {
            // We'll temporarily disable this until types are resolved
            // syncEngine.publisherSyncState(accountId: accountId)
            //     .receive(on: q)
            //     .sink { [weak self] state in
            //         self?.recompute(accountId)
            //     }
            //     .store(in: &bag)
        }
    }

    // MARK: Public API

    public func currentHealth(accountId: UUID) -> Health {
        q.sync { snaps[accountId]?.health ?? .ok }
    }

    public func publisherHealth(accountId: UUID) -> AnyPublisher<Health, Never> {
        ensureAccount(accountId)
        return q.sync { subjects[accountId]!.eraseToAnyPublisher() }
    }

    public func publisherSnapshot(accountId: UUID) -> AnyPublisher<Snapshot, Never> {
        ensureAccount(accountId)
        return q.sync { snapshotSubjects[accountId]!.eraseToAnyPublisher() }
    }

    // MARK: Recompute

    private func recompute(_ accountId: UUID) {
        let host = hostProvider?(accountId) ?? "unknown-host"
        let sum = metrics.summary(accountId: accountId, host: host)

        // Determine new health from metrics and retry policy
        let circuitOpen = retry.isOpen(RetryPolicy.Key(accountId: accountId, host: host))
        let newHealth: Health
        if circuitOpen || sum.health == .down {
            newHealth = .down
        } else if sum.health == .degraded || (sum.avgDurationsMs[.connect] ?? 0) > 2500 || (sum.avgDurationsMs[.fetch] ?? 0) > 3000 {
            newHealth = .degraded
        } else {
            newHealth = .ok
        }

        // Uptime accumulation (coarse): accumulate time spent in OK since windowStart
        let now = Date()
        var bucket = q.sync { uptime[accountId] ?? UptimeBucket(windowStart: now, okAccum: 0, lastHealth: newHealth, lastChange: now) }
        let delta = now.timeIntervalSince(bucket.lastChange)
        if bucket.lastHealth == .ok, delta > 0 { bucket.okAccum += delta }
        bucket.lastHealth = newHealth
        bucket.lastChange = now
        q.sync { uptime[accountId] = bucket }
        let elapsed = max(1.0, now.timeIntervalSince(bucket.windowStart))
        let uptimePct = min(1.0, max(0.0, bucket.okAccum / elapsed))

        // Error rate based on successes/failures observed by metrics
        let totalOps = max(1, sum.successCount + sum.failureCount)
        let errRate = Double(sum.failureCount) / Double(totalOps)

        // Build snapshot
        let snap = Snapshot(
            accountId: accountId,
            health: newHealth,
            lastSuccessAt: (sum.successCount > 0) ? now : nil,
            lastErrorAt: (sum.failureCount > 0) ? now : nil,
            consecutiveFailures: (sum.failureCount > 0 ? 1 : 0),
            circuitOpen: circuitOpen,
            latencyEMAms: sum.avgDurationsMs,
            uptimePercent: uptimePct,
            errorRate: errRate,
            updatedAt: now
        )

        // Publish health changes
        q.sync {
            snaps[accountId] = snap
            snapshotSubjects[accountId]?.send(snap)
            subjects[accountId]?.send(newHealth)
        }

        // Sync performance logging (warn on slow connect/fetch)
        if (sum.avgDurationsMs[.connect] ?? 0) > 4000 { MailLogger.shared.warn(.CONNECT, accountId: accountId, "Slow connect EMA: \(Int(sum.avgDurationsMs[.connect] ?? 0))ms") }
        if (sum.avgDurationsMs[.fetch] ?? 0) > 5000 { MailLogger.shared.warn(.FETCH, accountId: accountId, "Slow fetch EMA: \(Int(sum.avgDurationsMs[.fetch] ?? 0))ms") }

        // Alert on critical conditions
        if newHealth == .down || (errRate >= 0.5 && sum.failureCount >= 3) {
            NotificationCenter.default.post(name: .mailHealthCritical, object: accountId, userInfo: ["host": host, "errorRate": errRate])
        }
    }
}

public extension Notification.Name {
    static let mailHealthCritical = Notification.Name("mail.health.critical")
}
