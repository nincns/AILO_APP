// AILO_APP/Helpers/Monitoring/PerformanceMonitor_Phase8.swift
// PHASE 8: Performance Monitor
// Tracks processing times, cache hit rates, bottlenecks

import Foundation

// MARK: - Performance Metric

public struct PerformanceMetric: Sendable {
    public let operation: String
    public let duration: TimeInterval
    public let timestamp: Date
    public let metadata: [String: String]
    
    public init(operation: String, duration: TimeInterval, timestamp: Date = Date(), metadata: [String: String] = [:]) {
        self.operation = operation
        self.duration = duration
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

// MARK: - Performance Stats

public struct PerformanceStats: Sendable {
    public let operation: String
    public let count: Int
    public let totalDuration: TimeInterval
    public let averageDuration: TimeInterval
    public let minDuration: TimeInterval
    public let maxDuration: TimeInterval
    
    public init(operation: String, count: Int, totalDuration: TimeInterval, minDuration: TimeInterval, maxDuration: TimeInterval) {
        self.operation = operation
        self.count = count
        self.totalDuration = totalDuration
        self.averageDuration = count > 0 ? totalDuration / Double(count) : 0
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }
}

// MARK: - Cache Stats

public struct CacheStats: Sendable {
    public let hits: Int
    public let misses: Int
    public let hitRate: Double
    
    public init(hits: Int, misses: Int) {
        self.hits = hits
        self.misses = misses
        let total = hits + misses
        self.hitRate = total > 0 ? Double(hits) / Double(total) : 0
    }
}

// MARK: - Performance Monitor

public actor PerformanceMonitor {
    
    private var metrics: [PerformanceMetric] = []
    private var cacheHits: Int = 0
    private var cacheMisses: Int = 0
    
    // MARK: - Metric Recording
    
    public func record(operation: String, duration: TimeInterval, metadata: [String: String] = [:]) {
        let metric = PerformanceMetric(operation: operation, duration: duration, metadata: metadata)
        metrics.append(metric)
        
        // Keep only last 1000 metrics
        if metrics.count > 1000 {
            metrics.removeFirst(metrics.count - 1000)
        }
        
        if duration > 1.0 {
            print("⚠️  [PERF] Slow operation: \(operation) took \(String(format: "%.2f", duration))s")
        }
    }
    
    public func recordCacheHit() {
        cacheHits += 1
    }
    
    public func recordCacheMiss() {
        cacheMisses += 1
    }
    
    // MARK: - Timing Helper
    
    public func measure<T>(operation: String, metadata: [String: String] = [:], block: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await block()
        let duration = Date().timeIntervalSince(start)
        await record(operation: operation, duration: duration, metadata: metadata)
        return result
    }
    
    // MARK: - Statistics
    
    public func getStats(for operation: String) -> PerformanceStats? {
        let filtered = metrics.filter { $0.operation == operation }
        guard !filtered.isEmpty else { return nil }
        
        let durations = filtered.map { $0.duration }
        return PerformanceStats(
            operation: operation,
            count: filtered.count,
            totalDuration: durations.reduce(0, +),
            minDuration: durations.min() ?? 0,
            maxDuration: durations.max() ?? 0
        )
    }
    
    public func getAllStats() -> [PerformanceStats] {
        let operations = Set(metrics.map { $0.operation })
        return operations.compactMap { getStats(for: $0) }
    }
    
    public func getCacheStats() -> CacheStats {
        return CacheStats(hits: cacheHits, misses: cacheMisses)
    }
    
    // MARK: - Reports
    
    public func generateReport() -> String {
        var report = "📊 PERFORMANCE REPORT\n"
        report += "===================\n\n"
        
        let stats = getAllStats().sorted { $0.totalDuration > $1.totalDuration }
        
        for stat in stats {
            report += "Operation: \(stat.operation)\n"
            report += "  Count: \(stat.count)\n"
            report += "  Total: \(String(format: "%.2f", stat.totalDuration))s\n"
            report += "  Avg: \(String(format: "%.3f", stat.averageDuration))s\n"
            report += "  Min: \(String(format: "%.3f", stat.minDuration))s\n"
            report += "  Max: \(String(format: "%.3f", stat.maxDuration))s\n\n"
        }
        
        let cacheStats = getCacheStats()
        report += "Cache Stats:\n"
        report += "  Hits: \(cacheStats.hits)\n"
        report += "  Misses: \(cacheStats.misses)\n"
        report += "  Hit Rate: \(String(format: "%.1f", cacheStats.hitRate * 100))%\n"
        
        return report
    }
    
    public func reset() {
        metrics.removeAll()
        cacheHits = 0
        cacheMisses = 0
    }
}

// MARK: - Global Monitor

public let performanceMonitor = PerformanceMonitor()
