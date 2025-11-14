// AILO_APP/Services/Mail/FetchStrategy.swift
// PHASE 2: Intelligent Fetch Strategy
// Determines which MIME sections to fetch based on context and user preferences

import Foundation

/// Strategy for determining which MIME sections to fetch
public enum FetchStrategy {
    case minimal          // Only body text/html
    case standard         // Body + inline images
    case complete         // Everything including attachments
    case lazy             // Body only, attachments on-demand
    case offline          // Cache-only, no network
    
    /// Determine sections to fetch based on this strategy
    func sectionsToFetch(from structure: EnhancedBodyStructure) -> FetchPlan {
        var plan = FetchPlan()
        
        switch self {
        case .minimal:
            // Only fetch best body candidate
            if let body = structure.bodyCandidates.first {
                plan.sections.append(body.sectionId)
                plan.purposes[body.sectionId] = .bodyContent
            }
            
        case .standard:
            // Body + inline images
            if let body = structure.bodyCandidates.first {
                plan.sections.append(body.sectionId)
                plan.purposes[body.sectionId] = .bodyContent
            }
            
            for inline in structure.inlineParts where inline.mediaType.hasPrefix("image/") {
                plan.sections.append(inline.sectionId)
                plan.purposes[inline.sectionId] = .inlineImage
            }
            
        case .complete:
            // Everything
            for section in structure.sections {
                plan.sections.append(section.sectionId)
                
                if section.isBodyCandidate {
                    plan.purposes[section.sectionId] = .bodyContent
                } else if section.disposition == "inline" {
                    plan.purposes[section.sectionId] = .inlineImage
                } else if section.disposition == "attachment" {
                    plan.purposes[section.sectionId] = .attachment
                } else {
                    plan.purposes[section.sectionId] = .other
                }
            }
            
        case .lazy:
            // Only body - attachments will be fetched when user opens them
            if let body = structure.bodyCandidates.first {
                plan.sections.append(body.sectionId)
                plan.purposes[body.sectionId] = .bodyContent
            }
            
            // Store attachment metadata but don't fetch content
            plan.deferredAttachments = structure.attachments.map { $0.sectionId }
            
        case .offline:
            // Nothing to fetch
            plan.cacheOnly = true
        }
        
        return plan
    }
}

/// Plan for which sections to fetch
public struct FetchPlan {
    public var sections: [String] = []
    public var purposes: [String: SectionPurpose] = [:]
    public var deferredAttachments: [String] = []
    public var cacheOnly: Bool = false
    
    public init() {}
    
    /// Estimate total size to fetch (if available from structure)
    public func estimatedSize(from structure: EnhancedBodyStructure) -> Int {
        var total = 0
        for section in sections {
            if let info = structure.sections.first(where: { $0.sectionId == section }),
               let size = info.size {
                total += size
            }
        }
        return total
    }
    
    /// Check if plan is empty (nothing to fetch)
    public var isEmpty: Bool {
        sections.isEmpty && !cacheOnly
    }
}

/// Purpose of a section fetch
public enum SectionPurpose: String, Sendable {
    case bodyContent = "body"
    case inlineImage = "inline_image"
    case attachment = "attachment"
    case other = "other"
}

// MARK: - Adaptive Strategy

/// Adaptive fetch strategy based on connection quality and message size
public struct AdaptiveFetchStrategy {
    public let connectionSpeed: ConnectionSpeed
    public let messageSize: Int?
    public let userPreference: FetchStrategy
    
    public init(connectionSpeed: ConnectionSpeed = .unknown,
                messageSize: Int? = nil,
                userPreference: FetchStrategy = .standard) {
        self.connectionSpeed = connectionSpeed
        self.messageSize = messageSize
        self.userPreference = userPreference
    }
    
    /// Determine optimal strategy
    public func determineStrategy() -> FetchStrategy {
        // If offline or no connection, use cache only
        if connectionSpeed == .offline || connectionSpeed == .none {
            return .offline
        }
        
        // For slow connections, be conservative
        if connectionSpeed == .slow {
            // Large messages -> lazy loading
            if let size = messageSize, size > 1_000_000 { // 1MB
                return .lazy
            }
            // Otherwise minimal
            return .minimal
        }
        
        // For fast connections, respect user preference
        if connectionSpeed == .fast {
            return userPreference
        }
        
        // Default to standard
        return .standard
    }
}

/// Connection speed categories
public enum ConnectionSpeed: Sendable {
    case none       // No connection
    case offline    // Airplane mode / disabled
    case slow       // < 1 Mbps
    case moderate   // 1-10 Mbps
    case fast       // > 10 Mbps
    case unknown    // Can't determine
}

// MARK: - Fetch Priority

/// Priority ordering for section fetches
public struct FetchPriority {
    
    /// Assign priority scores to sections (higher = more important)
    public static func prioritize(sections: [SectionInfo]) -> [SectionInfo] {
        let scored = sections.map { section -> (section: SectionInfo, score: Int) in
            var score = 0
            
            // Body candidates are highest priority
            if section.isBodyCandidate {
                score += 1000
                // HTML preferred over plain text
                if section.mediaType.contains("html") {
                    score += 100
                }
            }
            
            // Inline images next
            if section.disposition == "inline" && section.mediaType.hasPrefix("image/") {
                score += 500
            }
            
            // Small files get priority (fetch quickly)
            if let size = section.size, size < 100_000 { // < 100KB
                score += 50
            }
            
            // Penalize large attachments (fetch last)
            if section.disposition == "attachment" {
                score -= 100
                if let size = section.size, size > 5_000_000 { // > 5MB
                    score -= 500
                }
            }
            
            return (section, score)
        }
        
        return scored.sorted { $0.score > $1.score }.map { $0.section }
    }
}

// MARK: - Fetch Progress Tracking

/// Tracks progress of multi-section fetch
public class FetchProgressTracker: @unchecked Sendable {
    private var completed: Set<String> = []
    private var failed: Set<String> = []
    private let total: Int
    private let lock = NSLock()
    
    public var progress: Double {
        lock.lock()
        defer { lock.unlock() }
        return total > 0 ? Double(completed.count) / Double(total) : 0
    }
    
    public init(totalSections: Int) {
        self.total = totalSections
    }
    
    public func markCompleted(_ sectionId: String) {
        lock.lock()
        defer { lock.unlock() }
        completed.insert(sectionId)
    }
    
    public func markFailed(_ sectionId: String) {
        lock.lock()
        defer { lock.unlock() }
        failed.insert(sectionId)
    }
    
    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed.count + failed.count >= total
    }
    
    public var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "Completed: \(completed.count)/\(total), Failed: \(failed.count)"
    }
}
