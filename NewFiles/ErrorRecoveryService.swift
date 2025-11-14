// AILO_APP/Services/ErrorRecovery/ErrorRecoveryService_Phase8.swift
// PHASE 8: Error Recovery Service
// Handles failures gracefully, retry logic, partial processing

import Foundation

// MARK: - Recovery Strategy

public enum RecoveryStrategy {
    case retry(maxAttempts: Int, delay: TimeInterval)
    case fallback(alternative: () async throws -> Void)
    case skip
    case abort
}

// MARK: - Error Context

public struct ErrorContext: Sendable {
    public let operation: String
    public let error: Error
    public let attemptNumber: Int
    public let timestamp: Date
    
    public init(operation: String, error: Error, attemptNumber: Int = 1, timestamp: Date = Date()) {
        self.operation = operation
        self.error = error
        self.attemptNumber = attemptNumber
        self.timestamp = timestamp
    }
}

// MARK: - Recovery Result

public enum RecoveryResult {
    case success
    case retrying(attempt: Int)
    case failed(reason: String)
    case skipped
}

// MARK: - Error Recovery Service

public actor ErrorRecoveryService {
    
    private var errorLog: [ErrorContext] = []
    
    // MARK: - Retry Logic
    
    public func retryOperation<T>(
        operation: String,
        maxAttempts: Int = 3,
        delay: TimeInterval = 1.0,
        block: () async throws -> T
    ) async throws -> T {
        
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                return try await block()
            } catch {
                lastError = error
                let context = ErrorContext(operation: operation, error: error, attemptNumber: attempt)
                errorLog.append(context)
                
                print("⚠️  [RECOVERY] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? NSError(domain: "Recovery", code: 8100, userInfo: nil)
    }
    
    // MARK: - Partial Processing
    
    public func processWithPartialSuccess<T>(
        items: [T],
        operation: String,
        processor: (T) async throws -> Void
    ) async -> (successful: Int, failed: Int, errors: [String]) {
        
        var successful = 0
        var failed = 0
        var errors: [String] = []
        
        for item in items {
            do {
                try await processor(item)
                successful += 1
            } catch {
                failed += 1
                errors.append("\(operation): \(error.localizedDescription)")
                
                let context = ErrorContext(operation: operation, error: error)
                errorLog.append(context)
            }
        }
        
        print("📊 [RECOVERY] Partial: \(successful) success, \(failed) failed")
        return (successful, failed, errors)
    }
    
    // MARK: - Fallback Handler
    
    public func withFallback<T>(
        primary: () async throws -> T,
        fallback: () async throws -> T
    ) async throws -> T {
        do {
            return try await primary()
        } catch {
            print("⚠️  [RECOVERY] Primary failed, trying fallback")
            return try await fallback()
        }
    }
    
    // MARK: - Error Analysis
    
    public func getFrequentErrors(limit: Int = 5) -> [(operation: String, count: Int)] {
        let grouped = Dictionary(grouping: errorLog, by: { $0.operation })
        return grouped.map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }
    
    public func getRecentErrors(limit: Int = 10) -> [ErrorContext] {
        return Array(errorLog.suffix(limit))
    }
    
    public func clearErrorLog() {
        errorLog.removeAll()
    }
}

// MARK: - Global Instance

public let errorRecovery = ErrorRecoveryService()
