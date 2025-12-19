// AILO_APP/Helpers/Limits/MessageLimitsService_Phase7.swift
// PHASE 7: Message Size Limits and Throttling
// Enforces size limits, throttles large downloads, provides user feedback

import Foundation

// MARK: - Limit Configuration

public struct MessageLimitsConfiguration {
    /// Maximum total message size (50 MB default)
    public let maxMessageSize: Int
    
    /// Maximum single attachment size (25 MB default)
    public let maxAttachmentSize: Int
    
    /// Maximum number of attachments per message (20 default)
    public let maxAttachmentCount: Int
    
    /// Maximum HTML body size (5 MB default)
    public let maxHTMLBodySize: Int
    
    /// Maximum total attachments size (100 MB default)
    public let maxTotalAttachmentsSize: Int
    
    /// Enable size warnings (before hard limit)
    public let enableWarnings: Bool
    
    /// Warning threshold (80% of limit)
    public let warningThreshold: Double
    
    public init(
        maxMessageSize: Int = 50 * 1024 * 1024,
        maxAttachmentSize: Int = 25 * 1024 * 1024,
        maxAttachmentCount: Int = 20,
        maxHTMLBodySize: Int = 5 * 1024 * 1024,
        maxTotalAttachmentsSize: Int = 100 * 1024 * 1024,
        enableWarnings: Bool = true,
        warningThreshold: Double = 0.8
    ) {
        self.maxMessageSize = maxMessageSize
        self.maxAttachmentSize = maxAttachmentSize
        self.maxAttachmentCount = maxAttachmentCount
        self.maxHTMLBodySize = maxHTMLBodySize
        self.maxTotalAttachmentsSize = maxTotalAttachmentsSize
        self.enableWarnings = enableWarnings
        self.warningThreshold = warningThreshold
    }
    
    public static let `default` = MessageLimitsConfiguration()
    
    /// Strict limits for mobile devices
    public static let mobile = MessageLimitsConfiguration(
        maxMessageSize: 25 * 1024 * 1024,
        maxAttachmentSize: 10 * 1024 * 1024,
        maxAttachmentCount: 10,
        maxHTMLBodySize: 2 * 1024 * 1024,
        maxTotalAttachmentsSize: 50 * 1024 * 1024
    )
}

// MARK: - Limit Check Result

public enum LimitCheckResult {
    case allowed
    case warning(message: String, percentage: Double)
    case exceeded(message: String, limit: Int, actual: Int)
    
    public var isAllowed: Bool {
        if case .allowed = self { return true }
        if case .warning = self { return true }
        return false
    }
    
    public var message: String? {
        switch self {
        case .allowed:
            return nil
        case .warning(let msg, _):
            return msg
        case .exceeded(let msg, _, _):
            return msg
        }
    }
}

// MARK: - Size Info

public struct MessageSizeInfo: Sendable {
    public let totalSize: Int
    public let bodySize: Int
    public let attachmentsSize: Int
    public let attachmentCount: Int
    public let largestAttachment: Int?
    
    public init(
        totalSize: Int,
        bodySize: Int,
        attachmentsSize: Int,
        attachmentCount: Int,
        largestAttachment: Int?
    ) {
        self.totalSize = totalSize
        self.bodySize = bodySize
        self.attachmentsSize = attachmentsSize
        self.attachmentCount = attachmentCount
        self.largestAttachment = largestAttachment
    }
    
    /// Format size for display
    public func formattedTotalSize() -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }
}

// MARK: - Message Limits Service

public actor MessageLimitsService {
    
    private let configuration: MessageLimitsConfiguration
    
    public init(configuration: MessageLimitsConfiguration = .default) {
        self.configuration = configuration
    }
    
    // MARK: - Pre-Fetch Checks
    
    /// Check if message size is acceptable before fetching
    public func checkMessageSize(serverReportedSize: Int) -> LimitCheckResult {
        let limit = configuration.maxMessageSize
        
        if serverReportedSize > limit {
            return .exceeded(
                message: "Message too large: \(formatBytes(serverReportedSize)) exceeds limit of \(formatBytes(limit))",
                limit: limit,
                actual: serverReportedSize
            )
        }
        
        if configuration.enableWarnings {
            let threshold = Int(Double(limit) * configuration.warningThreshold)
            if serverReportedSize > threshold {
                let percentage = (Double(serverReportedSize) / Double(limit)) * 100
                return .warning(
                    message: "Large message: \(formatBytes(serverReportedSize)) (\(Int(percentage))% of limit)",
                    percentage: percentage
                )
            }
        }
        
        return .allowed
    }
    
    /// Check attachment size before fetching
    public func checkAttachmentSize(size: Int) -> LimitCheckResult {
        let limit = configuration.maxAttachmentSize
        
        if size > limit {
            return .exceeded(
                message: "Attachment too large: \(formatBytes(size)) exceeds limit of \(formatBytes(limit))",
                limit: limit,
                actual: size
            )
        }
        
        if configuration.enableWarnings {
            let threshold = Int(Double(limit) * configuration.warningThreshold)
            if size > threshold {
                let percentage = (Double(size) / Double(limit)) * 100
                return .warning(
                    message: "Large attachment: \(formatBytes(size))",
                    percentage: percentage
                )
            }
        }
        
        return .allowed
    }
    
    /// Check total attachments
    public func checkAttachmentCount(count: Int) -> LimitCheckResult {
        let limit = configuration.maxAttachmentCount
        
        if count > limit {
            return .exceeded(
                message: "Too many attachments: \(count) exceeds limit of \(limit)",
                limit: limit,
                actual: count
            )
        }
        
        if configuration.enableWarnings {
            let threshold = Int(Double(limit) * configuration.warningThreshold)
            if count > threshold {
                return .warning(
                    message: "Many attachments: \(count) of \(limit)",
                    percentage: Double(count) / Double(limit) * 100
                )
            }
        }
        
        return .allowed
    }
    
    // MARK: - Post-Fetch Validation
    
    /// Validate fetched message size
    public func validateMessageSize(sizeInfo: MessageSizeInfo) -> LimitCheckResult {
        // Check total size
        let totalCheck = checkMessageSize(serverReportedSize: sizeInfo.totalSize)
        if case .exceeded = totalCheck {
            return totalCheck
        }
        
        // Check HTML body size
        if sizeInfo.bodySize > configuration.maxHTMLBodySize {
            return .exceeded(
                message: "HTML body too large: \(formatBytes(sizeInfo.bodySize))",
                limit: configuration.maxHTMLBodySize,
                actual: sizeInfo.bodySize
            )
        }
        
        // Check total attachments size
        if sizeInfo.attachmentsSize > configuration.maxTotalAttachmentsSize {
            return .exceeded(
                message: "Total attachments too large: \(formatBytes(sizeInfo.attachmentsSize))",
                limit: configuration.maxTotalAttachmentsSize,
                actual: sizeInfo.attachmentsSize
            )
        }
        
        // Check attachment count
        let countCheck = checkAttachmentCount(count: sizeInfo.attachmentCount)
        if case .exceeded = countCheck {
            return countCheck
        }
        
        return totalCheck // Return warning if any
    }
    
    // MARK: - Throttling
    
    /// Calculate throttle delay based on size (larger = longer delay)
    public func calculateThrottleDelay(size: Int) -> TimeInterval {
        // No throttling for small messages
        if size < 1_000_000 { // < 1 MB
            return 0
        }
        
        // Progressive throttling for larger messages
        let mb = Double(size) / 1_000_000.0
        
        if mb < 5 {
            return 0.1 // 100ms for 1-5 MB
        } else if mb < 10 {
            return 0.5 // 500ms for 5-10 MB
        } else if mb < 25 {
            return 1.0 // 1s for 10-25 MB
        } else {
            return 2.0 // 2s for > 25 MB
        }
    }
    
    /// Apply throttle delay
    public func applyThrottle(size: Int) async {
        let delay = calculateThrottleDelay(size: size)
        if delay > 0 {
            print("⏱️  [LIMITS] Throttling for \(String(format: "%.1f", delay))s (size: \(formatBytes(size)))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
    
    // MARK: - User Feedback
    
    /// Generate user-friendly size warning
    public func generateSizeWarning(sizeInfo: MessageSizeInfo) -> String? {
        let result = validateMessageSize(sizeInfo: sizeInfo)
        
        switch result {
        case .allowed:
            return nil
            
        case .warning(let message, _):
            return message
            
        case .exceeded(let message, _, _):
            return message
        }
    }
    
    /// Check if user confirmation needed before fetch
    public func needsUserConfirmation(serverSize: Int) -> Bool {
        // Require confirmation for messages > 20 MB
        return serverSize > 20 * 1024 * 1024
    }
    
    /// Generate confirmation prompt
    public func generateConfirmationPrompt(serverSize: Int) -> String {
        return """
        This message is very large (\(formatBytes(serverSize))).
        
        Downloading may take time and use significant data.
        
        Continue?
        """
    }
    
    // MARK: - Helpers
    
    private func formatBytes(_ bytes: Int) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    
    // MARK: - Progressive Loading Strategy
    
    /// Determine if message should be loaded progressively
    public func shouldLoadProgressively(serverSize: Int) -> Bool {
        return serverSize > 10 * 1024 * 1024 // > 10 MB
    }
    
    /// Get progressive loading strategy
    public func getProgressiveLoadingPlan(serverSize: Int) -> [String] {
        var plan: [String] = []
        
        plan.append("1. Fetch headers and structure (BODYSTRUCTURE)")
        plan.append("2. Fetch text/plain body (small)")
        
        if serverSize > 5 * 1024 * 1024 {
            plan.append("3. Fetch HTML body (on demand)")
            plan.append("4. Fetch inline images (on demand)")
            plan.append("5. Fetch attachments (user-initiated)")
        } else {
            plan.append("3. Fetch HTML body and inline images")
            plan.append("4. List attachments (fetch on demand)")
        }
        
        return plan
    }
}

// MARK: - SwiftUI Integration

import SwiftUI

/// Size warning banner
public struct SizeWarningBanner: View {
    let warning: String
    let onDismiss: () -> Void
    
    public init(warning: String, onDismiss: @escaping () -> Void) {
        self.warning = warning
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(warning)
                .font(.subheadline)
                .foregroundColor(.primary)
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

/// Size limit exceeded alert
public struct SizeLimitAlert: View {
    let message: String
    let limit: Int
    let actual: Int
    let onDismiss: () -> Void
    
    public init(message: String, limit: Int, actual: Int, onDismiss: @escaping () -> Void) {
        self.message = message
        self.limit = limit
        self.actual = actual
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            
            Text("Size Limit Exceeded")
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            
            HStack {
                VStack {
                    Text("Limit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatBytes(limit))
                        .font(.subheadline)
                }
                
                Divider()
                    .frame(height: 30)
                
                VStack {
                    Text("Actual")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatBytes(actual))
                        .font(.subheadline)
                        .foregroundColor(.red)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(8)
            
            Button("OK") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Usage Documentation

/*
 MESSAGE LIMITS SERVICE (Phase 7)
 =================================
 
 INITIALIZATION:
 ```swift
 let limitsService = MessageLimitsService(
     configuration: .default
 )
 
 // Mobile (stricter limits)
 let mobileLimits = MessageLimitsService(
     configuration: .mobile
 )
 ```
 
 PRE-FETCH CHECK:
 ```swift
 let result = await limitsService.checkMessageSize(
     serverReportedSize: imapSize
 )
 
 switch result {
 case .allowed:
     // Proceed with fetch
     break
     
 case .warning(let message, let percentage):
     // Show warning, allow fetch
     print("⚠️  \(message)")
     
 case .exceeded(let message, let limit, let actual):
     // Block fetch
     print("❌ \(message)")
     return
 }
 ```
 
 POST-FETCH VALIDATION:
 ```swift
 let sizeInfo = MessageSizeInfo(
     totalSize: message.size,
     bodySize: htmlBody.count,
     attachmentsSize: totalAttachmentSize,
     attachmentCount: attachments.count,
     largestAttachment: maxAttachmentSize
 )
 
 let result = await limitsService.validateMessageSize(sizeInfo: sizeInfo)
 ```
 
 THROTTLING:
 ```swift
 // Apply progressive throttling
 await limitsService.applyThrottle(size: messageSize)
 
 // Check if needs throttling
 let delay = await limitsService.calculateThrottleDelay(size: size)
 ```
 
 USER CONFIRMATION:
 ```swift
 if await limitsService.needsUserConfirmation(serverSize: size) {
     let prompt = await limitsService.generateConfirmationPrompt(serverSize: size)
     // Show alert
 }
 ```
 
 PROGRESSIVE LOADING:
 ```swift
 if await limitsService.shouldLoadProgressively(serverSize: size) {
     let plan = await limitsService.getProgressiveLoadingPlan(serverSize: size)
     for step in plan {
         print(step)
     }
 }
 ```
 
 SWIFTUI:
 ```swift
 // Warning banner
 if let warning = warningMessage {
     SizeWarningBanner(warning: warning) {
         warningMessage = nil
     }
 }
 
 // Limit exceeded alert
 SizeLimitAlert(
     message: "Message too large",
     limit: 50_000_000,
     actual: 75_000_000,
     onDismiss: { }
 )
 ```
 
 DEFAULT LIMITS:
 - Max message: 50 MB
 - Max attachment: 25 MB
 - Max attachment count: 20
 - Max HTML body: 5 MB
 - Max total attachments: 100 MB
 - Warning threshold: 80%
 
 MOBILE LIMITS:
 - Max message: 25 MB
 - Max attachment: 10 MB
 - Max attachment count: 10
 - Max HTML body: 2 MB
 - Max total attachments: 50 MB
 
 THROTTLING:
 - < 1 MB: no delay
 - 1-5 MB: 100ms
 - 5-10 MB: 500ms
 - 10-25 MB: 1s
 - > 25 MB: 2s
 
 FEATURES:
 - Pre-fetch size checks
 - Post-fetch validation
 - Progressive throttling
 - User confirmation prompts
 - Warning banners
 - Progressive loading strategy
 - Mobile-optimized limits
 */
