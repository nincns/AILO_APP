// PerformanceMonitor.swift
// Service für Performance-Monitoring und Metriken
// Phase 8: Comprehensive performance monitoring with detailed metrics

import Foundation
import os

// MARK: - Performance Monitor

class PerformanceMonitor {
    
    // MARK: - Metrics Storage
    
    private var metrics: [String: MetricData] = [:]
    private var activeOperations: [UUID: OperationData] = [:]
    private let queue = DispatchQueue(label: "performance.monitor", attributes: .concurrent)
    
    // Thresholds for performance alerts
    private let thresholds: PerformanceThresholds
    
    // Logger
    private let logger = Logger(subsystem: "com.app.mail", category: "Performance")
    
    // Memory tracking
    private var memoryBaseline: Int64 = 0
    
    // MARK: - Performance Thresholds
    
    struct PerformanceThresholds {
        let slowOperationThreshold: TimeInterval
        let criticalOperationThreshold: TimeInterval
        let memoryWarningThreshold: Int64
        let memoryCriticalThreshold: Int64
        
        static let `default` = PerformanceThresholds(
            slowOperationThreshold: 1.0,        // 1 second
            criticalOperationThreshold: 5.0,    // 5 seconds
            memoryWarningThreshold: 100 * 1024 * 1024,  // 100 MB
            memoryCriticalThreshold: 500 * 1024 * 1024  // 500 MB
        )
    }
    
    // MARK: - Initialization
    
    init(thresholds: PerformanceThresholds = .default) {
        self.thresholds = thresholds
        self.memoryBaseline = getCurrentMemoryUsage()
        
        // Start monitoring
        startMonitoring()
    }
    
    // MARK: - Main Measurement Interface
    
    @discardableResult
    func measure<T>(_ label: String,
                    metadata: [String: Any]? = nil,
                    block: () throws -> T) rethrows -> T {
        let operationId = UUID()
        let startTime = Date()
        let startMemory = getCurrentMemoryUsage()
        
        // Record operation start
        recordOperationStart(
            id: operationId,
            label: label,
            metadata: metadata
        )
        
        defer {
            let duration = Date().timeIntervalSince(startTime)
            let memoryDelta = getCurrentMemoryUsage() - startMemory
            
            // Record operation end
            recordOperationEnd(
                id: operationId,
                duration: duration,
                memoryDelta: memoryDelta,
                success: true
            )
            
            // Log if slow
            if duration > thresholds.slowOperationThreshold {
                logger.warning("⚠️ Slow operation: \(label) took \(String(format: "%.3f", duration))s")
            }
            
            // Check for performance issues
            checkPerformanceIssues(
                label: label,
                duration: duration,
                memoryDelta: memoryDelta
            )
        }
        
        return try block()
    }
    
    @discardableResult
    func measureAsync<T>(_ label: String,
                        metadata: [String: Any]? = nil,
                        block: () async throws -> T) async rethrows -> T {
        let operationId = UUID()
        let startTime = Date()
        let startMemory = getCurrentMemoryUsage()
        
        recordOperationStart(
            id: operationId,
            label: label,
            metadata: metadata
        )
        
        defer {
            let duration = Date().timeIntervalSince(startTime)
            let memoryDelta = getCurrentMemoryUsage() - startMemory
            
            recordOperationEnd(
                id: operationId,
                duration: duration,
                memoryDelta: memoryDelta,
                success: true
            )
            
            if duration > thresholds.slowOperationThreshold {
                logger.warning("⚠️ Slow async operation: \(label) took \(String(format: "%.3f", duration))s")
            }
            
            checkPerformanceIssues(
                label: label,
                duration: duration,
                memoryDelta: memoryDelta
            )
        }
        
        return try await block()
    }
    
    // MARK: - Manual Timing
    
    func startTiming(_ label: String) -> TimingToken {
        let token = TimingToken(
            id: UUID(),
            label: label,
            startTime: Date(),
            startMemory: getCurrentMemoryUsage()
        )
        
        recordOperationStart(
            id: token.id,
            label: label,
            metadata: nil
        )
        
        return token
    }
    
    func endTiming(_ token: TimingToken) {
        let duration = Date().timeIntervalSince(token.startTime)
        let memoryDelta = getCurrentMemoryUsage() - token.startMemory
        
        recordOperationEnd(
            id: token.id,
            duration: duration,
            memoryDelta: memoryDelta,
            success: true
        )
        
        print("⏱ \(token.label): \(String(format: "%.3f", duration))s, Memory: \(formatBytes(memoryDelta))")
    }
    
    // MARK: - Metrics Recording
    
    private func recordOperationStart(id: UUID, label: String, metadata: [String: Any]?) {
        queue.sync(flags: .barrier) {
            activeOperations[id] = OperationData(
                label: label,
                startTime: Date(),
                metadata: metadata
            )
        }
    }
    
    private func recordOperationEnd(id: UUID,
                                   duration: TimeInterval,
                                   memoryDelta: Int64,
                                   success: Bool) {
        queue.sync(flags: .barrier) {
            // Remove from active operations
            guard let operation = activeOperations.removeValue(forKey: id) else { return }
            
            // Update metrics
            if metrics[operation.label] == nil {
                metrics[operation.label] = MetricData(label: operation.label)
            }
            
            metrics[operation.label]?.record(
                duration: duration,
                memoryDelta: memoryDelta,
                success: success
            )
        }
    }
    
    // MARK: - Performance Analysis
    
    func getMetrics(for label: String) -> MetricSummary? {
        return queue.sync {
            guard let data = metrics[label] else { return nil }
            return data.summary
        }
    }
    
    func getAllMetrics() -> [String: MetricSummary] {
        return queue.sync {
            var summaries: [String: MetricSummary] = [:]
            for (label, data) in metrics {
                summaries[label] = data.summary
            }
            return summaries
        }
    }
    
    func getSlowOperations(threshold: TimeInterval? = nil) -> [SlowOperation] {
        let threshold = threshold ?? thresholds.slowOperationThreshold
        
        return queue.sync {
            var slowOps: [SlowOperation] = []
            
            for (label, data) in metrics {
                for timing in data.timings {
                    if timing > threshold {
                        slowOps.append(SlowOperation(
                            label: label,
                            duration: timing,
                            timestamp: Date() // Would need to store actual timestamp
                        ))
                    }
                }
            }
            
            return slowOps.sorted { $0.duration > $1.duration }
        }
    }
    
    // MARK: - Performance Issues Detection
    
    private func checkPerformanceIssues(label: String,
                                       duration: TimeInterval,
                                       memoryDelta: Int64) {
        // Check for critical operations
        if duration > thresholds.criticalOperationThreshold {
            reportCriticalPerformance(
                label: label,
                duration: duration,
                issue: .slowOperation
            )
        }
        
        // Check memory usage
        if memoryDelta > thresholds.memoryWarningThreshold {
            reportMemoryIssue(
                label: label,
                memoryDelta: memoryDelta,
                severity: memoryDelta > thresholds.memoryCriticalThreshold ? .critical : .warning
            )
        }
        
        // Check for memory leaks
        checkForMemoryLeak(label: label, memoryDelta: memoryDelta)
    }
    
    private func checkForMemoryLeak(label: String, memoryDelta: Int64) {
        // Simple leak detection: consistent memory growth
        queue.sync {
            if let data = metrics[label] {
                let recentDeltas = data.memoryDeltas.suffix(10)
                if recentDeltas.count >= 10 {
                    let allPositive = recentDeltas.allSatisfy { $0 > 0 }
                    let averageGrowth = recentDeltas.reduce(0, +) / Int64(recentDeltas.count)
                    
                    if allPositive && averageGrowth > 1024 * 1024 { // 1MB average growth
                        logger.error("🚨 Possible memory leak in: \(label)")
                        reportMemoryLeak(label: label, averageGrowth: averageGrowth)
                    }
                }
            }
        }
    }
    
    // MARK: - Reporting
    
    private func reportCriticalPerformance(label: String,
                                          duration: TimeInterval,
                                          issue: PerformanceIssue) {
        logger.critical("🚨 Critical performance issue in \(label): \(String(format: "%.3f", duration))s")
        
        // Send notification
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .performanceIssueDetected,
                object: nil,
                userInfo: [
                    "label": label,
                    "duration": duration,
                    "issue": issue
                ]
            )
        }
    }
    
    private func reportMemoryIssue(label: String,
                                  memoryDelta: Int64,
                                  severity: Severity) {
        let message = "Memory issue in \(label): \(formatBytes(memoryDelta))"
        
        switch severity {
        case .warning:
            logger.warning("⚠️ \(message)")
        case .critical:
            logger.critical("🚨 \(message)")
        }
    }
    
    private func reportMemoryLeak(label: String, averageGrowth: Int64) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .memoryLeakDetected,
                object: nil,
                userInfo: [
                    "label": label,
                    "averageGrowth": averageGrowth
                ]
            )
        }
    }
    
    // MARK: - Monitoring
    
    private func startMonitoring() {
        // Periodic monitoring
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            self.performPeriodicCheck()
        }
    }
    
    private func performPeriodicCheck() {
        let currentMemory = getCurrentMemoryUsage()
        let memoryGrowth = currentMemory - memoryBaseline

        if memoryGrowth > thresholds.memoryCriticalThreshold {
            logger.critical("🚨 Overall memory growth: \(self.formatBytes(memoryGrowth))")
        }

        // Clean old metrics
        cleanOldMetrics()
    }
    
    private func cleanOldMetrics() {
        queue.sync(flags: .barrier) {
            for (label, data) in metrics {
                // Keep only last 100 measurements
                if data.timings.count > 100 {
                    metrics[label]?.trimToLast(100)
                }
            }
        }
    }
    
    // MARK: - Memory Utilities
    
    private func getCurrentMemoryUsage() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    // MARK: - Reset
    
    func reset() {
        queue.sync(flags: .barrier) {
            metrics.removeAll()
            activeOperations.removeAll()
            memoryBaseline = getCurrentMemoryUsage()
        }
    }
}

// MARK: - Supporting Types

struct TimingToken {
    let id: UUID
    let label: String
    let startTime: Date
    let startMemory: Int64
}

private struct OperationData {
    let label: String
    let startTime: Date
    let metadata: [String: Any]?
}

private class MetricData {
    let label: String
    var timings: [TimeInterval] = []
    var memoryDeltas: [Int64] = []
    var successCount: Int = 0
    var failureCount: Int = 0
    
    init(label: String) {
        self.label = label
    }
    
    func record(duration: TimeInterval, memoryDelta: Int64, success: Bool) {
        timings.append(duration)
        memoryDeltas.append(memoryDelta)
        
        if success {
            successCount += 1
        } else {
            failureCount += 1
        }
    }
    
    func trimToLast(_ count: Int) {
        if timings.count > count {
            timings = Array(timings.suffix(count))
            memoryDeltas = Array(memoryDeltas.suffix(count))
        }
    }
    
    var summary: MetricSummary {
        let total = timings.reduce(0, +)
        let average = timings.isEmpty ? 0 : total / Double(timings.count)
        let min = timings.min() ?? 0
        let max = timings.max() ?? 0
        let median = calculateMedian(timings)
        let p95 = calculatePercentile(timings, percentile: 0.95)
        let p99 = calculatePercentile(timings, percentile: 0.99)
        
        let totalMemory = memoryDeltas.reduce(0, +)
        let avgMemory = memoryDeltas.isEmpty ? 0 : totalMemory / Int64(memoryDeltas.count)
        
        return MetricSummary(
            label: label,
            count: timings.count,
            totalTime: total,
            averageTime: average,
            minTime: min,
            maxTime: max,
            medianTime: median,
            p95Time: p95,
            p99Time: p99,
            totalMemory: totalMemory,
            averageMemory: avgMemory,
            successRate: Double(successCount) / Double(successCount + failureCount)
        )
    }
    
    private func calculateMedian(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        } else {
            return sorted[middle]
        }
    }
    
    private func calculatePercentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(Double(sorted.count - 1) * percentile)
        return sorted[index]
    }
}

struct MetricSummary {
    let label: String
    let count: Int
    let totalTime: TimeInterval
    let averageTime: TimeInterval
    let minTime: TimeInterval
    let maxTime: TimeInterval
    let medianTime: TimeInterval
    let p95Time: TimeInterval
    let p99Time: TimeInterval
    let totalMemory: Int64
    let averageMemory: Int64
    let successRate: Double
}

struct SlowOperation {
    let label: String
    let duration: TimeInterval
    let timestamp: Date
}

enum PerformanceIssue {
    case slowOperation
    case memoryLeak
    case highMemoryUsage
}

enum Severity {
    case warning
    case critical
}

// MARK: - Notification Names

extension Notification.Name {
    static let performanceIssueDetected = Notification.Name("performanceIssueDetected")
    static let memoryLeakDetected = Notification.Name("memoryLeakDetected")
}
