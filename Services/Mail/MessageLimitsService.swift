// MessageLimitsService.swift
// Service für Email-Größenlimits, Attachment-Beschränkungen und Throttling
// Phase 7: Message and attachment limits enforcement

import Foundation

// MARK: - Message Limits Service

class MessageLimitsService {
    
    // MARK: - Configuration
    
    struct LimitConfiguration {
        // Message limits
        let maxMessageSize: Int
        let maxHeaderSize: Int
        let maxBodySize: Int
        
        // Attachment limits
        let maxAttachmentSize: Int
        let maxAttachmentCount: Int
        let maxTotalAttachmentSize: Int
        let maxInlineImageSize: Int
        
        // Processing limits
        let maxMimeDepth: Int
        let maxProcessingTime: TimeInterval
        let maxRenderCacheSize: Int
        
        // Rate limits
        let maxMessagesPerMinute: Int
        let maxAttachmentsPerHour: Int
        
        // Default configuration
        static let `default` = LimitConfiguration(
            maxMessageSize: 50 * 1024 * 1024,        // 50 MB
            maxHeaderSize: 1 * 1024 * 1024,          // 1 MB
            maxBodySize: 25 * 1024 * 1024,           // 25 MB
            maxAttachmentSize: 25 * 1024 * 1024,     // 25 MB per attachment
            maxAttachmentCount: 20,                   // 20 attachments per message
            maxTotalAttachmentSize: 100 * 1024 * 1024, // 100 MB total
            maxInlineImageSize: 5 * 1024 * 1024,     // 5 MB per inline image
            maxMimeDepth: 10,                         // Max nesting depth
            maxProcessingTime: 30,                    // 30 seconds
            maxRenderCacheSize: 10 * 1024 * 1024,    // 10 MB rendered content
            maxMessagesPerMinute: 60,                 // 60 messages/min
            maxAttachmentsPerHour: 500                // 500 attachments/hour
        )
        
        // Strict configuration for untrusted sources
        static let strict = LimitConfiguration(
            maxMessageSize: 10 * 1024 * 1024,        // 10 MB
            maxHeaderSize: 256 * 1024,               // 256 KB
            maxBodySize: 5 * 1024 * 1024,            // 5 MB
            maxAttachmentSize: 5 * 1024 * 1024,      // 5 MB
            maxAttachmentCount: 5,                    // 5 attachments
            maxTotalAttachmentSize: 20 * 1024 * 1024, // 20 MB total
            maxInlineImageSize: 1 * 1024 * 1024,     // 1 MB
            maxMimeDepth: 5,                          // Reduced nesting
            maxProcessingTime: 10,                    // 10 seconds
            maxRenderCacheSize: 5 * 1024 * 1024,     // 5 MB
            maxMessagesPerMinute: 10,                 // 10 messages/min
            maxAttachmentsPerHour: 50                 // 50 attachments/hour
        )
    }
    
    private let configuration: LimitConfiguration
    private var rateLimiter: RateLimiter
    
    // MARK: - Initialization
    
    init(configuration: LimitConfiguration = .default) {
        self.configuration = configuration
        self.rateLimiter = RateLimiter()
    }
    
    // MARK: - Message Validation
    
    func validateMessage(size: Int, headerSize: Int, bodySize: Int) throws {
        // Check total message size
        if size > configuration.maxMessageSize {
            throw LimitError.messageTooLarge(
                actual: size,
                limit: configuration.maxMessageSize
            )
        }
        
        // Check header size
        if headerSize > configuration.maxHeaderSize {
            throw LimitError.headersTooLarge(
                actual: headerSize,
                limit: configuration.maxHeaderSize
            )
        }
        
        // Check body size
        if bodySize > configuration.maxBodySize {
            throw LimitError.bodyTooLarge(
                actual: bodySize,
                limit: configuration.maxBodySize
            )
        }
    }
    
    // MARK: - Attachment Validation
    
    func validateAttachments(_ attachments: [AttachmentInfo]) throws {
        // Check attachment count
        if attachments.count > configuration.maxAttachmentCount {
            throw LimitError.tooManyAttachments(
                actual: attachments.count,
                limit: configuration.maxAttachmentCount
            )
        }
        
        var totalSize = 0
        
        for attachment in attachments {
            // Check individual attachment size
            if attachment.size > configuration.maxAttachmentSize {
                throw LimitError.attachmentTooLarge(
                    filename: attachment.filename,
                    actual: attachment.size,
                    limit: configuration.maxAttachmentSize
                )
            }
            
            // Check inline image size
            if attachment.isInline && attachment.size > configuration.maxInlineImageSize {
                throw LimitError.inlineImageTooLarge(
                    filename: attachment.filename,
                    actual: attachment.size,
                    limit: configuration.maxInlineImageSize
                )
            }
            
            totalSize += attachment.size
        }
        
        // Check total attachment size
        if totalSize > configuration.maxTotalAttachmentSize {
            throw LimitError.totalAttachmentSizeTooLarge(
                actual: totalSize,
                limit: configuration.maxTotalAttachmentSize
            )
        }
    }
    
    // MARK: - MIME Structure Validation
    
    func validateMimeStructure(depth: Int, partCount: Int) throws {
        // Check MIME depth
        if depth > configuration.maxMimeDepth {
            throw LimitError.mimeDepthExceeded(
                actual: depth,
                limit: configuration.maxMimeDepth
            )
        }
        
        // Check total part count (prevent DoS)
        let maxParts = configuration.maxAttachmentCount * 3 // Rough estimate
        if partCount > maxParts {
            throw LimitError.tooManyMimeParts(
                actual: partCount,
                limit: maxParts
            )
        }
    }
    
    // MARK: - Processing Limits
    
    func checkProcessingTime(startTime: Date) throws {
        let elapsed = Date().timeIntervalSince(startTime)
        
        if elapsed > configuration.maxProcessingTime {
            throw LimitError.processingTimeout(
                elapsed: elapsed,
                limit: configuration.maxProcessingTime
            )
        }
    }
    
    func validateRenderCache(htmlSize: Int, textSize: Int) throws {
        let totalSize = htmlSize + textSize
        
        if totalSize > configuration.maxRenderCacheSize {
            throw LimitError.renderCacheTooLarge(
                actual: totalSize,
                limit: configuration.maxRenderCacheSize
            )
        }
    }
    
    // MARK: - Rate Limiting
    
    func checkMessageRate(accountId: UUID) throws {
        let key = "messages:\(accountId)"
        
        if !rateLimiter.checkRate(
            key: key,
            limit: configuration.maxMessagesPerMinute,
            window: 60
        ) {
            throw LimitError.messageRateLimitExceeded(
                limit: configuration.maxMessagesPerMinute
            )
        }
    }
    
    func checkAttachmentRate(accountId: UUID) throws {
        let key = "attachments:\(accountId)"
        
        if !rateLimiter.checkRate(
            key: key,
            limit: configuration.maxAttachmentsPerHour,
            window: 3600
        ) {
            throw LimitError.attachmentRateLimitExceeded(
                limit: configuration.maxAttachmentsPerHour
            )
        }
    }
    
    // MARK: - Limit Suggestions
    
    func suggestLimits(for messageStats: MessageStatistics) -> LimitSuggestions {
        var suggestions: [String] = []
        var recommendedConfig = configuration
        
        // Analyze message size patterns
        if messageStats.averageSize > configuration.maxMessageSize / 2 {
            suggestions.append("Consider increasing maxMessageSize - average is \(messageStats.averageSize) bytes")
        }
        
        if messageStats.maxAttachmentCount > configuration.maxAttachmentCount / 2 {
            suggestions.append("Consider increasing maxAttachmentCount - seen up to \(messageStats.maxAttachmentCount)")
        }
        
        // Check for frequent limit hits
        if messageStats.limitViolations > 10 {
            suggestions.append("Frequent limit violations detected (\(messageStats.limitViolations))")
            
            // Suggest relaxed limits
            recommendedConfig = LimitConfiguration(
                maxMessageSize: configuration.maxMessageSize * 2,
                maxHeaderSize: configuration.maxHeaderSize,
                maxBodySize: configuration.maxBodySize * 2,
                maxAttachmentSize: configuration.maxAttachmentSize * 2,
                maxAttachmentCount: configuration.maxAttachmentCount * 2,
                maxTotalAttachmentSize: configuration.maxTotalAttachmentSize * 2,
                maxInlineImageSize: configuration.maxInlineImageSize,
                maxMimeDepth: configuration.maxMimeDepth,
                maxProcessingTime: configuration.maxProcessingTime,
                maxRenderCacheSize: configuration.maxRenderCacheSize,
                maxMessagesPerMinute: configuration.maxMessagesPerMinute,
                maxAttachmentsPerHour: configuration.maxAttachmentsPerHour
            )
        }
        
        return LimitSuggestions(
            suggestions: suggestions,
            recommendedConfiguration: recommendedConfig
        )
    }
}

// MARK: - Rate Limiter

private class RateLimiter {
    private var buckets: [String: RateBucket] = [:]
    private let queue = DispatchQueue(label: "ratelimiter", attributes: .concurrent)
    
    func checkRate(key: String, limit: Int, window: TimeInterval) -> Bool {
        return queue.sync(flags: .barrier) {
            let now = Date()
            
            // Get or create bucket
            if buckets[key] == nil {
                buckets[key] = RateBucket(windowStart: now, count: 0)
            }
            
            var bucket = buckets[key]!
            
            // Reset if window expired
            if now.timeIntervalSince(bucket.windowStart) > window {
                bucket = RateBucket(windowStart: now, count: 0)
            }
            
            // Check limit
            if bucket.count >= limit {
                return false
            }
            
            // Increment counter
            bucket.count += 1
            buckets[key] = bucket
            
            return true
        }
    }
    
    func reset(key: String) {
        queue.sync(flags: .barrier) {
            buckets[key] = nil
        }
    }
}

private struct RateBucket {
    let windowStart: Date
    var count: Int
}

// MARK: - Supporting Types

struct AttachmentInfo {
    let filename: String
    let size: Int
    let isInline: Bool
}

struct MessageStatistics {
    let averageSize: Int
    let maxAttachmentCount: Int
    let limitViolations: Int
}

struct LimitSuggestions {
    let suggestions: [String]
    let recommendedConfiguration: MessageLimitsService.LimitConfiguration
}

// MARK: - Limit Errors

enum LimitError: Error, LocalizedError {
    case messageTooLarge(actual: Int, limit: Int)
    case headersTooLarge(actual: Int, limit: Int)
    case bodyTooLarge(actual: Int, limit: Int)
    case attachmentTooLarge(filename: String, actual: Int, limit: Int)
    case tooManyAttachments(actual: Int, limit: Int)
    case totalAttachmentSizeTooLarge(actual: Int, limit: Int)
    case inlineImageTooLarge(filename: String, actual: Int, limit: Int)
    case mimeDepthExceeded(actual: Int, limit: Int)
    case tooManyMimeParts(actual: Int, limit: Int)
    case processingTimeout(elapsed: TimeInterval, limit: TimeInterval)
    case renderCacheTooLarge(actual: Int, limit: Int)
    case messageRateLimitExceeded(limit: Int)
    case attachmentRateLimitExceeded(limit: Int)
    
    var errorDescription: String? {
        switch self {
        case .messageTooLarge(let actual, let limit):
            return "Message too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .headersTooLarge(let actual, let limit):
            return "Headers too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .bodyTooLarge(let actual, let limit):
            return "Body too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .attachmentTooLarge(let filename, let actual, let limit):
            return "Attachment '\(filename)' too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .tooManyAttachments(let actual, let limit):
            return "Too many attachments: \(actual) (limit: \(limit))"
        case .totalAttachmentSizeTooLarge(let actual, let limit):
            return "Total attachment size too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .inlineImageTooLarge(let filename, let actual, let limit):
            return "Inline image '\(filename)' too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .mimeDepthExceeded(let actual, let limit):
            return "MIME structure too deep: \(actual) levels (limit: \(limit))"
        case .tooManyMimeParts(let actual, let limit):
            return "Too many MIME parts: \(actual) (limit: \(limit))"
        case .processingTimeout(let elapsed, let limit):
            return "Processing timeout: \(String(format: "%.1f", elapsed))s (limit: \(String(format: "%.1f", limit))s)"
        case .renderCacheTooLarge(let actual, let limit):
            return "Render cache too large: \(formatBytes(actual)) (limit: \(formatBytes(limit)))"
        case .messageRateLimitExceeded(let limit):
            return "Message rate limit exceeded: \(limit) per minute"
        case .attachmentRateLimitExceeded(let limit):
            return "Attachment rate limit exceeded: \(limit) per hour"
        }
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
