// AILO_APP/Configuration/Services/Mail/RetryPolicy.swift
// Encapsulates exponential backoff and circuit‑breaker logic for transient network errors.
// Used by IMAPConnection, MailSyncEngine, and SMTPClient.
// Thread-safety: internal synchronization via a private serial queue.

import Foundation

public final class RetryPolicy {

    // MARK: Types

    /// High-level error kinds. Keep in sync with MailMetrics.ErrorKind if you wire them together.
    public enum ErrorKind: String, CaseIterable, Sendable {
        case dns, timeout, refused, unreachable, auth, protocolErr, parseErr, io, unknown
    }
    
    /// Classification of errors for retry decisions
    public enum ErrorClass: String, Sendable {
        case transient
        case permanent
    }

    /// A logical circuit key (e.g., per account & host).
    public struct Key: Hashable, Sendable {
        public let accountId: UUID
        public let host: String
        public init(accountId: UUID, host: String) {
            self.accountId = accountId
            self.host = host
        }
    }

    /// Backoff profile describing the delay growth and jitter.
    public struct BackoffProfile: Sendable {
        public let base: TimeInterval        // initial delay (seconds)
        public let factor: Double            // exponential factor (e.g., 2.0)
        public let max: TimeInterval         // maximum delay cap (seconds)
        public let jitter: Double            // 0.0 ... 1.0 (percentage of delay)

        public init(base: TimeInterval, factor: Double = 2.0, max: TimeInterval, jitter: Double = 0.2) {
            self.base = base
            self.factor = factor
            self.max = max
            self.jitter = Swift.min(Swift.max(jitter, 0.0), 1.0)
        }
    }

    private struct Circuit {
        var consecutiveFailures: Int = 0
        var lastFailureAt: Date? = nil
        var openUntil: Date? = nil
    }

    // MARK: Singleton

    public static let shared = RetryPolicy()
    private init() {}

    // MARK: Storage

    private let q = DispatchQueue(label: "mail.retry.policy.queue")
    private var circuits: [Key: Circuit] = [:]

    // Retry ceilings and classifications
    private var maxRetriesDefault: Int = 5
    private var perKindMaxRetries: [ErrorKind: Int] = [:]
    private var classifications: [ErrorKind: ErrorClass] = [
        .dns: .transient,
        .timeout: .transient,
        .refused: .transient,
        .unreachable: .transient,
        .io: .transient,
        .unknown: .transient,
        .auth: .permanent,
        .protocolErr: .permanent,
        .parseErr: .permanent
    ]

    // Profiles: global default, per error kind, and per-account overrides.
    private var defaultProfile = BackoffProfile(base: 0.8, factor: 2.0, max: 60.0, jitter: 0.25)
    private var kindProfiles: [ErrorKind: BackoffProfile] = [
        .timeout: BackoffProfile(base: 1.2, factor: 2.0, max: 90.0, jitter: 0.30),
        .refused: BackoffProfile(base: 1.0, factor: 1.8, max: 45.0, jitter: 0.25),
        .unreachable: BackoffProfile(base: 2.0, factor: 2.0, max: 120.0, jitter: 0.35),
        .dns: BackoffProfile(base: 3.0, factor: 1.5, max: 90.0, jitter: 0.25),
        .auth: BackoffProfile(base: 10.0, factor: 1.0, max: 10.0, jitter: 0.0), // no exponential; fast fail
        .protocolErr: BackoffProfile(base: 5.0, factor: 1.5, max: 30.0, jitter: 0.20),
        .parseErr: BackoffProfile(base: 2.0, factor: 1.5, max: 20.0, jitter: 0.20),
        .io: BackoffProfile(base: 1.0, factor: 1.7, max: 60.0, jitter: 0.30),
        .unknown: BackoffProfile(base: 1.0, factor: 1.8, max: 60.0, jitter: 0.25)
    ]
    private var perAccountKindProfiles: [Key: [ErrorKind: BackoffProfile]] = [:]

    // Circuit breaker thresholds (can be tuned)
    private var openThresholdFailures = 3            // open after N consecutive failures
    private var baseOpenDuration: TimeInterval = 10  // seconds (multiplied by failure streak)

    // MARK: Configuration

    public func setDefaultProfile(_ profile: BackoffProfile) {
        q.sync { self.defaultProfile = profile }
    }

    public func setProfile(for kind: ErrorKind, profile: BackoffProfile) {
        q.sync { self.kindProfiles[kind] = profile }
    }

    public func setProfile(for key: Key, kind: ErrorKind, profile: BackoffProfile) {
        q.sync {
            var map = perAccountKindProfiles[key] ?? [:]
            map[kind] = profile
            perAccountKindProfiles[key] = map
        }
    }

    public func setCircuit(openAfter failures: Int, baseOpenDurationSec: TimeInterval) {
        q.sync {
            self.openThresholdFailures = Swift.max(1, failures)
            self.baseOpenDuration = Swift.max(1.0, baseOpenDurationSec)
        }
    }
    
    public func setMaxRetriesDefault(_ n: Int) {
        q.sync { self.maxRetriesDefault = max(0, n) }
    }

    public func setMaxRetries(for kind: ErrorKind, _ n: Int) {
        q.sync { self.perKindMaxRetries[kind] = max(0, n) }
    }

    public func setClassification(for kind: ErrorKind, _ cls: ErrorClass) {
        q.sync { self.classifications[kind] = cls }
    }

    // MARK: Public API

    /// Computes the next delay based on error kind and attempt number (1-based).
    /// Adds jitter in the range [-jitter..+jitter] proportionally to the delay.
    public func nextDelay(for kind: ErrorKind, attempt: Int, key: Key? = nil) -> TimeInterval {
        q.sync {
            let profile = profileFor(kind: kind, key: key)
            let a = max(1, attempt - 1) // attempt 1 => exponent 0
            let raw = Swift.min(profile.max, profile.base * pow(profile.factor, Double(a)))
            let jitterSpan = raw * profile.jitter
            let jitter = (Double.random(in: -1.0...1.0) * jitterSpan)
            let delay = Swift.max(0.0, raw + jitter)
            return delay
        }
    }

    /// Records a failure for the circuit. If threshold exceeded, the circuit opens (blocks) for a cooldown.
    public func recordFailure(_ key: Key, kind: ErrorKind) {
        q.sync {
            var c = circuits[key] ?? Circuit()
            c.consecutiveFailures &+= 1
            c.lastFailureAt = Date()
            if c.consecutiveFailures >= openThresholdFailures {
                // open circuit with an increasing cooldown
                let multiplier = min(5, c.consecutiveFailures - openThresholdFailures + 1)
                c.openUntil = Date().addingTimeInterval(baseOpenDuration * Double(multiplier))
            }
            circuits[key] = c
        }
    }

    /// Records a success: closes the circuit and resets failure counters.
    public func recordSuccess(_ key: Key) {
        q.sync {
            var c = circuits[key] ?? Circuit()
            c.consecutiveFailures = 0
            c.openUntil = nil
            circuits[key] = c
        }
    }

    /// Returns true if the circuit is OPEN (i.e., calls should be short-circuited).
    public func isOpen(_ key: Key) -> Bool {
        q.sync {
            guard let c = circuits[key], let until = c.openUntil else { return false }
            if Date() >= until {
                // auto-close after cooldown
                var nc = c
                nc.openUntil = nil
                circuits[key] = nc
                return false
            }
            return true
        }
    }

    /// Optional: expose remaining cooldown for UI/debug.
    public func remainingCooldown(_ key: Key) -> TimeInterval {
        q.sync {
            guard let until = circuits[key]?.openUntil else { return 0 }
            return Swift.max(0.0, until.timeIntervalSinceNow)
        }
    }
    
    /// Determines whether another retry should be attempted for the given error kind and attempt number (1-based).
    /// If a `key` is provided and the circuit is open, this returns false.
    public func shouldRetry(kind: ErrorKind, attempt: Int, key: Key? = nil) -> Bool {
        return q.sync {
            if let key, isOpen(key) { return false }
            let cls = classifications[kind] ?? .transient
            guard cls == .transient else { return false }
            let cap = perKindMaxRetries[kind] ?? maxRetriesDefault
            return attempt <= max(0, cap)
        }
    }

    /// Returns remaining retries given the attempt number (1-based) and error kind.
    public func remainingRetries(kind: ErrorKind, attempt: Int) -> Int {
        return q.sync {
            let cap = perKindMaxRetries[kind] ?? maxRetriesDefault
            return max(0, cap - max(0, attempt))
        }
    }

    // MARK: Internals

    private func profileFor(kind: ErrorKind, key: Key?) -> BackoffProfile {
        if let key, let map = perAccountKindProfiles[key], let p = map[kind] { return p }
        if let p = kindProfiles[kind] { return p }
        return defaultProfile
    }
}
