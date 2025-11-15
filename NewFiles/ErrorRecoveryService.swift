// ErrorRecoveryService.swift
// Service für Fehlerbehandlung und Recovery-Strategien
// Phase 8: Comprehensive error recovery with intelligent retry mechanisms

import Foundation

// MARK: - Error Recovery Service

class ErrorRecoveryService {
    
    // MARK: - Configuration
    
    struct RecoveryConfiguration {
        let maxRetries: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let backoffMultiplier: Double
        let jitterRange: Double
        let enableCircuitBreaker: Bool
        let circuitBreakerThreshold: Int
        let circuitBreakerTimeout: TimeInterval
        
        static let `default` = RecoveryConfiguration(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 30.0,
            backoffMultiplier: 2.0,
            jitterRange: 0.1,
            enableCircuitBreaker: true,
            circuitBreakerThreshold: 5,
            circuitBreakerTimeout: 60.0
        )
        
        static let aggressive = RecoveryConfiguration(
            maxRetries: 5,
            baseDelay: 0.5,
            maxDelay: 60.0,
            backoffMultiplier: 1.5,
            jitterRange: 0.2,
            enableCircuitBreaker: true,
            circuitBreakerThreshold: 10,
            circuitBreakerTimeout: 30.0
        )
        
        static let conservative = RecoveryConfiguration(
            maxRetries: 2,
            baseDelay: 2.0,
            maxDelay: 20.0,
            backoffMultiplier: 3.0,
            jitterRange: 0.05,
            enableCircuitBreaker: false,
            circuitBreakerThreshold: 3,
            circuitBreakerTimeout: 120.0
        )
    }
    
    // MARK: - Properties
    
    private let configuration: RecoveryConfiguration
    private var retryState: [String: RetryState] = [:]
    private var circuitBreakers: [String: CircuitBreaker] = [:]
    private let queue = DispatchQueue(label: "error.recovery", attributes: .concurrent)
    
    // Error patterns and recovery strategies
    private let recoveryStrategies: [ErrorPattern: RecoveryStrategy]
    
    // Statistics
    private var statistics = RecoveryStatistics()
    
    // MARK: - Initialization
    
    init(configuration: RecoveryConfiguration = .default) {
        self.configuration = configuration
        self.recoveryStrategies = Self.defaultRecoveryStrategies()
    }
    
    // MARK: - Main Recovery Interface
    
    func handleError(_ error: Error, context: ErrorContext) async -> RecoveryAction {
        let contextKey = context.key
        
        // Check circuit breaker
        if configuration.enableCircuitBreaker {
            if let breaker = getCircuitBreaker(for: contextKey) {
                if breaker.state == .open {
                    print("⚡ [Recovery] Circuit breaker OPEN for: \(contextKey)")
                    statistics.circuitBreakerTrips += 1
                    return .fail(CircuitBreakerError.open)
                }
            }
        }
        
        // Get or create retry state
        let state = getRetryState(for: contextKey)
        
        // Check if we can retry
        guard state.attemptCount < configuration.maxRetries else {
            print("❌ [Recovery] Max retries reached for: \(contextKey)")
            statistics.maxRetriesReached += 1
            recordFailure(for: contextKey)
            return .fail(error)
        }
        
        // Find recovery strategy
        let strategy = findStrategy(for: error)
        
        // Check if error is recoverable
        guard strategy.isRecoverable(error, state: state) else {
            print("🚫 [Recovery] Error not recoverable: \(error)")
            statistics.nonRecoverableErrors += 1
            return .fail(error)
        }
        
        // Calculate delay with exponential backoff
        let delay = calculateDelay(attemptNumber: state.attemptCount)
        
        // Update state
        updateRetryState(for: contextKey, attemptCount: state.attemptCount + 1)
        
        print("🔄 [Recovery] Retry #\(state.attemptCount + 1) after \(String(format: "%.2f", delay))s for: \(contextKey)")
        statistics.totalRetries += 1
        
        // Apply recovery action
        let action = strategy.action(for: error, context: context)
        
        return .retry(delay: delay, action: action)
    }
    
    // MARK: - Recovery Capabilities
    
    func canRecover(from error: Error) -> Bool {
        let strategy = findStrategy(for: error)
        return strategy.isRecoverable(error, state: RetryState())
    }
    
    func suggestRecovery(for error: Error) -> RecoverySuggestion {
        let strategy = findStrategy(for: error)
        
        return RecoverySuggestion(
            canRecover: strategy.isRecoverable(error, state: RetryState()),
            suggestedAction: strategy.suggestedAction,
            estimatedRecoveryTime: strategy.estimatedRecoveryTime,
            userMessage: strategy.userMessage(for: error)
        )
    }
    
    // MARK: - State Management
    
    func reset(context: String) {
        queue.sync(flags: .barrier) {
            retryState[context] = nil
            circuitBreakers[context]?.reset()
        }
        
        print("♻️ [Recovery] Reset state for: \(context)")
    }
    
    func recordSuccess(for context: String) {
        queue.sync(flags: .barrier) {
            retryState[context] = nil
            circuitBreakers[context]?.recordSuccess()
        }
        
        statistics.successfulRecoveries += 1
    }
    
    private func recordFailure(for context: String) {
        queue.sync(flags: .barrier) {
            if configuration.enableCircuitBreaker {
                if circuitBreakers[context] == nil {
                    circuitBreakers[context] = CircuitBreaker(
                        threshold: configuration.circuitBreakerThreshold,
                        timeout: configuration.circuitBreakerTimeout
                    )
                }
                circuitBreakers[context]?.recordFailure()
            }
        }
    }
    
    // MARK: - Retry State
    
    private func getRetryState(for key: String) -> RetryState {
        return queue.sync {
            return retryState[key] ?? RetryState()
        }
    }
    
    private func updateRetryState(for key: String, attemptCount: Int) {
        queue.sync(flags: .barrier) {
            if retryState[key] == nil {
                retryState[key] = RetryState()
            }
            retryState[key]?.attemptCount = attemptCount
            retryState[key]?.lastAttempt = Date()
        }
    }
    
    // MARK: - Circuit Breaker
    
    private func getCircuitBreaker(for key: String) -> CircuitBreaker? {
        return queue.sync {
            return circuitBreakers[key]
        }
    }
    
    // MARK: - Delay Calculation
    
    private func calculateDelay(attemptNumber: Int) -> TimeInterval {
        // Exponential backoff with jitter
        let exponentialDelay = configuration.baseDelay * pow(configuration.backoffMultiplier, Double(attemptNumber))
        let clampedDelay = min(exponentialDelay, configuration.maxDelay)
        
        // Add jitter to prevent thundering herd
        let jitter = Double.random(in: -configuration.jitterRange...configuration.jitterRange)
        let finalDelay = clampedDelay * (1.0 + jitter)
        
        return max(finalDelay, 0.1) // Minimum 100ms
    }
    
    // MARK: - Strategy Selection
    
    private func findStrategy(for error: Error) -> RecoveryStrategy {
        // Check for exact match
        for (pattern, strategy) in recoveryStrategies {
            if pattern.matches(error) {
                return strategy
            }
        }
        
        // Return default strategy
        return RecoveryStrategy.default
    }
    
    // MARK: - Default Recovery Strategies
    
    private static func defaultRecoveryStrategies() -> [ErrorPattern: RecoveryStrategy] {
        return [
            // Network errors
            ErrorPattern.network: RecoveryStrategy(
                isRecoverableCheck: { error, state in
                    return state.attemptCount < 5
                },
                action: { error, context in
                    return .refreshConnection
                },
                suggestedAction: "Retry with connection refresh",
                estimatedRecoveryTime: 5.0,
                userMessage: { _ in "Network connection issue. Retrying..." }
            ),
            
            // Timeout errors
            ErrorPattern.timeout: RecoveryStrategy(
                isRecoverableCheck: { error, state in
                    return state.attemptCount < 3
                },
                action: { error, context in
                    return .increaseTimeout
                },
                suggestedAction: "Retry with increased timeout",
                estimatedRecoveryTime: 10.0,
                userMessage: { _ in "Operation timed out. Retrying with longer timeout..." }
            ),
            
            // Rate limit errors
            ErrorPattern.rateLimit: RecoveryStrategy(
                isRecoverableCheck: { error, state in
                    return true // Always recoverable with delay
                },
                action: { error, context in
                    return .backoff
                },
                suggestedAction: "Wait and retry",
                estimatedRecoveryTime: 60.0,
                userMessage: { _ in "Rate limit reached. Waiting before retry..." }
            ),
            
            // Database errors
            ErrorPattern.database: RecoveryStrategy(
                isRecoverableCheck: { error, state in
                    // Only retry for transient database errors
                    if let dbError = error as? DatabaseError {
                        return dbError.isTransient && state.attemptCount < 3
                    }
                    return false
                },
                action: { error, context in
                    return .reconnectDatabase
                },
                suggestedAction: "Retry with database reconnection",
                estimatedRecoveryTime: 2.0,
                userMessage: { _ in "Database connection issue. Reconnecting..." }
            ),
            
            // Storage errors
            ErrorPattern.storage: RecoveryStrategy(
                isRecoverableCheck: { error, state in
                    if let storageError = error as? StorageError {
                        return storageError.isTemporary && state.attemptCount < 2
                    }
                    return false
                },
                action: { error, context in
                    return .cleanupStorage
                },
                suggestedAction: "Cleanup and retry",
                estimatedRecoveryTime: 5.0,
                userMessage: { _ in "Storage issue. Cleaning up and retrying..." }
            )
        ]
    }
    
    // MARK: - Statistics
    
    func getStatistics() -> RecoveryStatistics {
        return statistics
    }
    
    func resetStatistics() {
        statistics = RecoveryStatistics()
    }
}

// MARK: - Circuit Breaker

private class CircuitBreaker {
    enum State {
        case closed
        case open
        case halfOpen
    }
    
    private var state: State = .closed
    private var failureCount: Int = 0
    private var lastFailureTime: Date?
    private let threshold: Int
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "circuit.breaker")
    
    init(threshold: Int, timeout: TimeInterval) {
        self.threshold = threshold
        self.timeout = timeout
    }
    
    var currentState: State {
        return queue.sync {
            // Check if we should transition from open to half-open
            if state == .open,
               let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) > timeout {
                state = .halfOpen
            }
            return state
        }
    }
    
    func recordSuccess() {
        queue.sync {
            failureCount = 0
            state = .closed
            lastFailureTime = nil
        }
    }
    
    func recordFailure() {
        queue.sync {
            failureCount += 1
            lastFailureTime = Date()
            
            if failureCount >= threshold {
                state = .open
            } else if state == .halfOpen {
                state = .open
            }
        }
    }
    
    func reset() {
        queue.sync {
            state = .closed
            failureCount = 0
            lastFailureTime = nil
        }
    }
}

// MARK: - Supporting Types

struct ErrorContext {
    let key: String
    let component: String
    let operation: String
    let metadata: [String: Any]
}

struct RetryState {
    var attemptCount: Int = 0
    var lastAttempt: Date?
}

struct RecoveryStrategy {
    let isRecoverableCheck: (Error, RetryState) -> Bool
    let action: (Error, ErrorContext) -> RecoveryActionType
    let suggestedAction: String
    let estimatedRecoveryTime: TimeInterval
    let userMessage: (Error) -> String
    
    func isRecoverable(_ error: Error, state: RetryState) -> Bool {
        return isRecoverableCheck(error, state)
    }
    
    static let `default` = RecoveryStrategy(
        isRecoverableCheck: { _, state in state.attemptCount < 3 },
        action: { _, _ in .none },
        suggestedAction: "Retry operation",
        estimatedRecoveryTime: 5.0,
        userMessage: { _ in "An error occurred. Retrying..." }
    )
}

struct RecoverySuggestion {
    let canRecover: Bool
    let suggestedAction: String
    let estimatedRecoveryTime: TimeInterval
    let userMessage: String
}

struct RecoveryStatistics {
    var totalRetries: Int = 0
    var successfulRecoveries: Int = 0
    var maxRetriesReached: Int = 0
    var nonRecoverableErrors: Int = 0
    var circuitBreakerTrips: Int = 0
    
    var recoveryRate: Double {
        guard totalRetries > 0 else { return 0 }
        return Double(successfulRecoveries) / Double(totalRetries)
    }
}

enum RecoveryAction {
    case retry(delay: TimeInterval, action: RecoveryActionType)
    case fail(Error)
}

enum RecoveryActionType {
    case none
    case refreshConnection
    case increaseTimeout
    case backoff
    case reconnectDatabase
    case cleanupStorage
    case clearCache
    case reauthenticate
}

// MARK: - Error Patterns

struct ErrorPattern {
    let matcher: (Error) -> Bool
    
    func matches(_ error: Error) -> Bool {
        return matcher(error)
    }
    
    static let network = ErrorPattern { error in
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost]
                .contains(urlError.code)
        }
        return false
    }
    
    static let timeout = ErrorPattern { error in
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        return (error as? ProcessingError) == .timeout
    }
    
    static let rateLimit = ErrorPattern { error in
        if let httpError = error as? HTTPError {
            return httpError.statusCode == 429
        }
        return false
    }
    
    static let database = ErrorPattern { error in
        return error is DatabaseError
    }
    
    static let storage = ErrorPattern { error in
        return error is StorageError
    }
}

// MARK: - Error Types

struct HTTPError: Error {
    let statusCode: Int
}

struct DatabaseError: Error {
    let isTransient: Bool
}

struct StorageError: Error {
    let isTemporary: Bool
}

enum CircuitBreakerError: Error {
    case open
}
