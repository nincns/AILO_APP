// CircuitBreaker.swift
// Robust circuit breaker with Closed/Open/HalfOpen states.
// Use from call sites that perform network operations to avoid hammering failing services.
// Thread-safety: treat as value type and mutate on a serial context.

import Foundation

public struct CircuitBreaker: Sendable {
    public enum State: Equatable, Sendable {
        case closed(Int)                 // consecutive failure count
        case open(until: Date)           // short-circuit until this time
        case halfOpen(remainingProbes: Int)
    }

    // Configuration
    public var openAfterFailures: Int            // threshold to open
    public var baseOpenDuration: TimeInterval    // base cooldown (seconds)
    public var maxOpenMultiplier: Int            // cap for cooldown multiplier
    public var halfOpenProbes: Int               // how many probes before fully close

    // State
    public private(set) var state: State

    public init(openAfterFailures: Int = 3,
                baseOpenDuration: TimeInterval = 10,
                maxOpenMultiplier: Int = 5,
                halfOpenProbes: Int = 3,
                state: State = .closed(0)) {
        self.openAfterFailures = max(1, openAfterFailures)
        self.baseOpenDuration = max(1.0, baseOpenDuration)
        self.maxOpenMultiplier = max(1, maxOpenMultiplier)
        self.halfOpenProbes = max(1, halfOpenProbes)
        self.state = state
    }

    /// Record a result and transition the breaker if needed. Returns an optional delay (seconds)
    /// that the caller may want to wait before the next attempt (e.g., when state is Open).
    @discardableResult
    public mutating func record(_ result: Result<Void, Error>) -> TimeInterval? {
        let now = Date()
        switch state {
        case .open(let until):
            if now < until { return until.timeIntervalSince(now) }
            // Cooldown passed → allow a few probes
            state = .halfOpen(remainingProbes: halfOpenProbes)
            return 0

        case .halfOpen(let remaining):
            switch result {
            case .success:
                let next = remaining - 1
                if next <= 0 { state = .closed(0); return nil }
                state = .halfOpen(remainingProbes: next)
                return 0
            case .failure:
                // Immediate reopen with increased cooldown
                let mult = min(maxOpenMultiplier, openMultiplierFromFailures(openAfterFailures))
                let until = now.addingTimeInterval(baseOpenDuration * Double(mult))
                state = .open(until: until)
                return until.timeIntervalSince(now)
            }

        case .closed(let failures):
            switch result {
            case .success:
                state = .closed(0)
                return nil
            case .failure:
                let next = failures + 1
                if next >= openAfterFailures {
                    // Open with cooldown; duration scales with overrun
                    let mult = min(maxOpenMultiplier, next - openAfterFailures + 1)
                    let until = now.addingTimeInterval(baseOpenDuration * Double(mult))
                    state = .open(until: until)
                    return until.timeIntervalSince(now)
                } else {
                    state = .closed(next)
                    return 0
                }
            }
        }
    }

    private func openMultiplierFromFailures(_ failures: Int) -> Int {
        let over = max(0, failures - openAfterFailures)
        return min(maxOpenMultiplier, 1 + over)
    }
}
