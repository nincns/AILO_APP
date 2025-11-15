// RenderCacheDAO.swift
// Data Access Object für Render Cache Management
// Phase 3-4: Render cache for processed email content

import Foundation
import SQLite3

// MARK: - Render Cache DAO

class RenderCacheDAO: NSObject {
    
    // MARK: - Properties
    
    private let writeDAO: MailWriteDAO
    private let readDAO: MailReadDAO
    private let performanceMonitor: PerformanceMonitor?
    
    // Cache configuration
    private let configuration: CacheConfiguration
    
    // In-memory cache for frequently accessed items
    private var memoryCache = NSCache<NSString, RenderCacheEntry>()
    
    // Statistics
    private var statistics = CacheStatistics()
    private let queue = DispatchQueue(label: "rendercache.dao", attributes: .concurrent)
    
    // MARK: - Configuration
    
    struct CacheConfiguration {
        let maxMemoryCacheItems: Int
        let maxMemoryCacheSizeBytes: Int
        let defaultGeneratorVersion: Int
        let enableCompression: Bool
        let compressionThreshold: Int
        let expirationDays: Int
        
        static let `default` = CacheConfiguration(
            maxMemoryCacheItems: 100,
            maxMemoryCacheSizeBytes: 50 * 1024 * 1024, // 50MB
            defaultGeneratorVersion: 1,
            enableCompression: true,
            compressionThreshold: 10 * 1024, // 10KB
            expirationDays: 30
        )
    }
    
    // MARK: - Initialization
    
    init(writeDAO: MailWriteDAO,
         readDAO: MailReadDAO,
         configuration: CacheConfiguration = .default,
         performanceMonitor: PerformanceMonitor? = nil) {
        
        self.writeDAO = writeDAO
        self.readDAO = readDAO
        self.configuration = configuration
        self.performanceMonitor = performanceMonitor
        
        // Configure memory cache
        memoryCache.countLimit = configuration.maxMemoryCacheItems
        memoryCache.totalCostLimit = configuration.maxMemoryCacheSizeBytes
        
        // Set up cache delegate
        memoryCache.delegate = self
    }
    
    // MARK: - Store Cache Entry
    
    func store(messageId: UUID,
               html: String?,
               text: String?,
               generatorVersion: Int? = nil) throws {
        
        let version = generatorVersion ?? configuration.defaultGeneratorVersion
        
        performanceMonitor?.measure("render_cache_store") {
            try performStore(messageId: messageId,
                           html: html,
                           text: text,
                           generatorVersion: version)
        } ?? try performStore(messageId: messageId,
                             html: html,
                             text: text,
                             generatorVersion: version)
    }
    
    private func performStore(messageId: UUID,
                             html: String?,
                             text: String?,
                             generatorVersion: Int) throws {
        
        print("💾 [RenderCache] Storing cache for message: \(messageId)")
        
        // Apply compression if needed
        let processedHtml = try processForStorage(html, type: "html")
        let processedText = try processForStorage(text, type: "text")
        
        // Store in database
        try writeDAO.storeRenderCache(
            messageId: messageId,
            html: processedHtml,
            text: processedText,
            generatorVersion: generatorVersion
        )
        
        // Update memory cache
        let entry = RenderCacheEntry(
            messageId: messageId,
            htmlRendered: html,
            textRendered: text,
            generatedAt: Date(),
            generatorVersion: generatorVersion,
            compressed: processedHtml != html || processedText != text
        )
        
        let cost = (html?.count ?? 0) + (text?.count ?? 0)
        memoryCache.setObject(entry, forKey: messageId.uuidString as NSString, cost: cost)
        
        // Update statistics
        updateStatistics { stats in
            stats.storeCount += 1
            stats.totalBytesStored += cost
        }
        
        print("✅ [RenderCache] Stored successfully (size: \(formatBytes(cost)))")
    }
    
    // MARK: - Retrieve Cache Entry
    
    func retrieve(messageId: UUID) throws -> RenderCacheEntry? {
        return try performanceMonitor?.measure("render_cache_retrieve") {
            try performRetrieve(messageId: messageId)
        } ?? performRetrieve(messageId: messageId)
    }
    
    private func performRetrieve(messageId: UUID) throws -> RenderCacheEntry? {
        // Check memory cache first
        if let cached = memoryCache.object(forKey: messageId.uuidString as NSString) {
            print("💨 [RenderCache] Retrieved from memory: \(messageId)")
            
            updateStatistics { stats in
                stats.memoryCacheHits += 1
            }
            
            return cached
        }
        
        // Fetch from database
        guard let dbEntry = try readDAO.getRenderCache(messageId: messageId) else {
            print("❌ [RenderCache] Not found: \(messageId)")
            
            updateStatistics { stats in
                stats.cacheMisses += 1
            }
            
            return nil
        }
        
        // Process retrieved data
        let html = try processFromStorage(dbEntry.htmlRendered, type: "html")
        let text = try processFromStorage(dbEntry.textRendered, type: "text")
        
        let entry = RenderCacheEntry(
            messageId: messageId,
            htmlRendered: html,
            textRendered: text,
            generatedAt: dbEntry.generatedAt,
            generatorVersion: dbEntry.generatorVersion,
            compressed: false
        )
        
        // Add to memory cache
        let cost = (html?.count ?? 0) + (text?.count ?? 0)
        memoryCache.setObject(entry, forKey: messageId.uuidString as NSString, cost: cost)
        
        print("📁 [RenderCache] Retrieved from database: \(messageId)")
        
        updateStatistics { stats in
            stats.databaseCacheHits += 1
            stats.totalBytesRetrieved += cost
        }
        
        return entry
    }
    
    // MARK: - Invalidate Cache
    
    func invalidate(messageId: UUID) throws {
        print("🗑 [RenderCache] Invalidating: \(messageId)")
        
        // Remove from memory cache
        memoryCache.removeObject(forKey: messageId.uuidString as NSString)
        
        // Remove from database
        try writeDAO.invalidateRenderCache(messageId: messageId)
        
        updateStatistics { stats in
            stats.invalidationCount += 1
        }
    }
    
    func invalidateAll() throws {
        print("🗑 [RenderCache] Invalidating all caches")
        
        // Clear memory cache
        memoryCache.removeAllObjects()
        
        // Clear database
        try writeDAO.invalidateAllRenderCaches()
        
        updateStatistics { stats in
            stats.invalidationCount += stats.storeCount
            stats.storeCount = 0
        }
    }
    
    func invalidateOldCaches(olderThanVersion: Int) throws {
        print("🗑 [RenderCache] Invalidating caches older than version: \(olderThanVersion)")
        
        let invalidated = try writeDAO.invalidateRenderCachesOlderThan(version: olderThanVersion)
        
        // Clear affected items from memory cache
        memoryCache.removeAllObjects() // Simplest approach
        
        updateStatistics { stats in
            stats.invalidationCount += invalidated
        }
        
        print("✅ [RenderCache] Invalidated \(invalidated) old caches")
    }
    
    func invalidateExpired() throws {
        let expirationDate = Date().addingTimeInterval(
            -TimeInterval(configuration.expirationDays * 24 * 60 * 60)
        )
        
        print("🗑 [RenderCache] Invalidating caches older than: \(expirationDate)")
        
        let invalidated = try writeDAO.invalidateRenderCachesOlderThan(date: expirationDate)
        
        updateStatistics { stats in
            stats.expiredCount += invalidated
        }
        
        print("✅ [RenderCache] Invalidated \(invalidated) expired caches")
    }
    
    // MARK: - Batch Operations
    
    func preloadCaches(for messageIds: [UUID]) async {
        print("📥 [RenderCache] Preloading \(messageIds.count) caches")
        
        await withTaskGroup(of: Void.self) { group in
            for messageId in messageIds {
                group.addTask {
                    _ = try? self.retrieve(messageId: messageId)
                }
            }
        }
    }
    
    func getCacheSizes() throws -> [UUID: Int] {
        return try readDAO.getRenderCacheSizes()
    }
    
    // MARK: - Compression
    
    private func processForStorage(_ content: String?, type: String) throws -> String? {
        guard let content = content else { return nil }
        
        // Check if compression should be applied
        guard configuration.enableCompression,
              content.count > configuration.compressionThreshold else {
            return content
        }
        
        // Compress content
        guard let data = content.data(using: .utf8),
              let compressed = compress(data) else {
            return content
        }
        
        // Only use compressed if smaller
        if compressed.count < data.count {
            print("🗜 [RenderCache] Compressed \(type): \(data.count) → \(compressed.count) bytes")
            return compressed.base64EncodedString()
        }
        
        return content
    }
    
    private func processFromStorage(_ content: String?, type: String) throws -> String? {
        guard let content = content else { return nil }
        
        // Check if content is compressed (base64 encoded)
        if content.hasPrefix("H4sI") { // gzip magic bytes in base64
            guard let data = Data(base64Encoded: content),
                  let decompressed = decompress(data),
                  let result = String(data: decompressed, encoding: .utf8) else {
                throw CacheError.decompressionFailed
            }
            
            print("📤 [RenderCache] Decompressed \(type)")
            return result
        }
        
        return content
    }
    
    private func compress(_ data: Data) -> Data? {
        return try? (data as NSData).compressed(using: .zlib) as Data
    }
    
    private func decompress(_ data: Data) -> Data? {
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }
    
    // MARK: - Statistics
    
    private func updateStatistics(_ update: (inout CacheStatistics) -> Void) {
        queue.sync(flags: .barrier) {
            update(&statistics)
        }
    }
    
    func getStatistics() -> CacheStatistics {
        return queue.sync { statistics }
    }
    
    func resetStatistics() {
        queue.sync(flags: .barrier) {
            statistics = CacheStatistics()
        }
    }
    
    // MARK: - Maintenance
    
    func performMaintenance() async throws {
        print("🔧 [RenderCache] Performing maintenance...")
        
        // Remove expired caches
        try invalidateExpired()
        
        // Optimize database
        try optimizeDatabase()
        
        // Update statistics
        let stats = try getDatabaseStatistics()
        
        updateStatistics { localStats in
            localStats.totalEntries = stats.totalEntries
            localStats.totalSizeBytes = stats.totalSizeBytes
        }
        
        print("✅ [RenderCache] Maintenance completed")
    }
    
    private func optimizeDatabase() throws {
        try writeDAO.executeSQL("VACUUM render_cache")
        try writeDAO.executeSQL("ANALYZE render_cache")
    }
    
    private func getDatabaseStatistics() throws -> DatabaseStatistics {
        return try readDAO.getRenderCacheStatistics()
    }
    
    // MARK: - Utilities
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - NSCacheDelegate

extension RenderCacheDAO: NSCacheDelegate {
    
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        if let entry = obj as? RenderCacheEntry {
            print("♻️ [RenderCache] Evicting from memory: \(entry.messageId)")
            
            updateStatistics { stats in
                stats.memoryEvictionCount += 1
            }
        }
    }
}

// MARK: - Supporting Types

public class RenderCacheEntry: NSObject {
    let messageId: UUID
    let htmlRendered: String?
    let textRendered: String?
    let generatedAt: Date
    let generatorVersion: Int
    let compressed: Bool
    
    init(messageId: UUID,
         htmlRendered: String?,
         textRendered: String?,
         generatedAt: Date,
         generatorVersion: Int,
         compressed: Bool = false) {
        
        self.messageId = messageId
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
        self.generatedAt = generatedAt
        self.generatorVersion = generatorVersion
        self.compressed = compressed
        super.init()
    }
    
    var isEmpty: Bool {
        return htmlRendered == nil && textRendered == nil
    }
    
    var sizeBytes: Int {
        return (htmlRendered?.count ?? 0) + (textRendered?.count ?? 0)
    }
}

struct CacheStatistics {
    var storeCount: Int = 0
    var memoryCacheHits: Int = 0
    var databaseCacheHits: Int = 0
    var cacheMisses: Int = 0
    var invalidationCount: Int = 0
    var expiredCount: Int = 0
    var memoryEvictionCount: Int = 0
    var totalBytesStored: Int = 0
    var totalBytesRetrieved: Int = 0
    var totalEntries: Int = 0
    var totalSizeBytes: Int64 = 0
    
    var hitRate: Double {
        let hits = memoryCacheHits + databaseCacheHits
        let total = hits + cacheMisses
        return total > 0 ? Double(hits) / Double(total) : 0
    }
    
    var memoryCacheHitRate: Double {
        let total = memoryCacheHits + databaseCacheHits + cacheMisses
        return total > 0 ? Double(memoryCacheHits) / Double(total) : 0
    }
}

struct DatabaseStatistics {
    let totalEntries: Int
    let totalSizeBytes: Int64
    let oldestEntry: Date?
    let newestEntry: Date?
}

enum CacheError: Error {
    case compressionFailed
    case decompressionFailed
    case invalidData
}

// MARK: - DAO Extensions for RenderCache

extension MailWriteDAO {
    
    func invalidateAllRenderCaches() throws {
        try ensureOpen()
        
        let sql = "DELETE FROM \(MailSchema.tRenderCache)"
        
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw dbError(context: "invalidateAllRenderCaches")
        }
    }
    
    func invalidateRenderCachesOlderThan(version: Int) throws -> Int {
        try ensureOpen()
        
        let sql = """
            DELETE FROM \(MailSchema.tRenderCache)
            WHERE generator_version < ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        sqlite3_bind_int(stmt, 1, Int32(version))
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "invalidateRenderCachesOlderThan")
        }
        
        return Int(sqlite3_changes(db))
    }
    
    func invalidateRenderCachesOlderThan(date: Date) throws -> Int {
        try ensureOpen()
        
        let sql = """
            DELETE FROM \(MailSchema.tRenderCache)
            WHERE generated_at < ?
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970))
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw dbError(context: "invalidateRenderCachesOlderThan")
        }
        
        return Int(sqlite3_changes(db))
    }
    
    func executeSQL(_ sql: String) throws {
        try ensureOpen()
        
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw dbError(context: "executeSQL")
        }
    }
}

extension MailReadDAO {
    
    func getRenderCacheSizes() throws -> [UUID: Int] {
        try ensureOpen()
        
        let sql = """
            SELECT message_id, 
                   LENGTH(html_rendered) + LENGTH(text_rendered) as size
            FROM \(MailSchema.tRenderCache)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        var sizes: [UUID: Int] = [:]
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let messageId = stmt.columnUUID(0) {
                let size = Int(sqlite3_column_int(stmt, 1))
                sizes[messageId] = size
            }
        }
        
        return sizes
    }
    
    func getRenderCacheStatistics() throws -> DatabaseStatistics {
        try ensureOpen()
        
        let sql = """
            SELECT COUNT(*) as count,
                   SUM(LENGTH(html_rendered) + LENGTH(text_rendered)) as total_size,
                   MIN(generated_at) as oldest,
                   MAX(generated_at) as newest
            FROM \(MailSchema.tRenderCache)
        """
        
        let stmt = try prepare(sql)
        defer { finalize(stmt) }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return DatabaseStatistics(
                totalEntries: 0,
                totalSizeBytes: 0,
                oldestEntry: nil,
                newestEntry: nil
            )
        }
        
        let count = Int(sqlite3_column_int(stmt, 0))
        let totalSize = sqlite3_column_int64(stmt, 1)
        let oldest = sqlite3_column_int64(stmt, 2) > 0 ?
            Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2))) : nil
        let newest = sqlite3_column_int64(stmt, 3) > 0 ?
            Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3))) : nil
        
        return DatabaseStatistics(
            totalEntries: count,
            totalSizeBytes: totalSize,
            oldestEntry: oldest,
            newestEntry: newest
        )
    }
}
