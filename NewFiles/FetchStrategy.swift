// FetchStrategy.swift
// Intelligente IMAP Fetch-Strategie basierend auf BODYSTRUCTURE

import Foundation

// MARK: - Fetch Strategy

enum FetchPriority {
    case immediate  // Body parts needed for display
    case deferred   // Attachments to fetch on-demand
    case skip       // Parts we don't need
}

struct FetchPlan {
    let sections: [FetchSection]
    let deferredSections: [FetchSection]
    
    struct FetchSection {
        let partId: String
        let section: String  // IMAP section specifier like "1.2"
        let expectedSize: Int
        let mimeType: String
        let priority: FetchPriority
        let isBodyCandidate: Bool
    }
}

class FetchStrategy {
    
    // MARK: - Analyze BODYSTRUCTURE
    
    func createFetchPlan(from bodyStructure: IMAPBodyStructure) -> FetchPlan {
        var immediateSections: [FetchPlan.FetchSection] = []
        var deferredSections: [FetchPlan.FetchSection] = []
        
        // Traverse the BODYSTRUCTURE tree
        analyzePart(bodyStructure.rootPart,
                   partPath: "",
                   immediate: &immediateSections,
                   deferred: &deferredSections)
        
        return FetchPlan(sections: immediateSections,
                        deferredSections: deferredSections)
    }
    
    // MARK: - Recursive Part Analysis
    
    private func analyzePart(_ part: IMAPBodyPart,
                           partPath: String,
                           immediate: inout [FetchPlan.FetchSection],
                           deferred: inout [FetchPlan.FetchSection]) {
        
        let currentPath = partPath.isEmpty ? "1" : partPath
        
        switch part.type {
        case .text(let subtype, let charset):
            // Text parts are usually body candidates
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: part.size ?? 0,
                mimeType: "text/\(subtype)",
                priority: .immediate,
                isBodyCandidate: true
            )
            immediate.append(section)
            
        case .multipart(let subtype, let parts):
            // Process multipart containers
            if subtype == "alternative" {
                // For alternative, pick the best part
                processAlternative(parts: parts,
                                 basePath: currentPath,
                                 immediate: &immediate,
                                 deferred: &deferred)
            } else {
                // Process all subparts
                for (index, subpart) in parts.enumerated() {
                    let subPath = "\(currentPath).\(index + 1)"
                    analyzePart(subpart,
                              partPath: subPath,
                              immediate: &immediate,
                              deferred: &deferred)
                }
            }
            
        case .image(let subtype, let contentId):
            // Images with Content-ID are inline, fetch immediately
            let priority: FetchPriority = contentId != nil ? .immediate : .deferred
            
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: part.size ?? 0,
                mimeType: "image/\(subtype)",
                priority: priority,
                isBodyCandidate: false
            )
            
            if priority == .immediate {
                immediate.append(section)
            } else {
                deferred.append(section)
            }
            
        case .attachment(let mimeType, let filename):
            // Regular attachments are deferred
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: part.size ?? 0,
                mimeType: mimeType,
                priority: .deferred,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .message:
            // Embedded messages might need special handling
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: part.size ?? 0,
                mimeType: "message/rfc822",
                priority: .deferred,
                isBodyCandidate: false
            )
            deferred.append(section)
        }
    }
    
    // MARK: - Handle multipart/alternative
    
    private func processAlternative(parts: [IMAPBodyPart],
                                  basePath: String,
                                  immediate: inout [FetchPlan.FetchSection],
                                  deferred: inout [FetchPlan.FetchSection]) {
        
        // Prefer HTML over plain text
        var bestPart: (index: Int, part: IMAPBodyPart)?
        
        for (index, part) in parts.enumerated() {
            if case .text(let subtype, _) = part.type {
                if subtype == "html" {
                    bestPart = (index, part)
                    break  // HTML found, use it
                } else if subtype == "plain" && bestPart == nil {
                    bestPart = (index, part)  // Keep plain as fallback
                }
            }
        }
        
        // Fetch the best part immediately
        if let best = bestPart {
            let subPath = "\(basePath).\(best.index + 1)"
            analyzePart(best.part,
                      partPath: subPath,
                      immediate: &immediate,
                      deferred: &deferred)
        }
        
        // Other alternatives go to deferred
        for (index, part) in parts.enumerated() {
            if bestPart?.index != index {
                let subPath = "\(basePath).\(index + 1)"
                analyzePart(part,
                          partPath: subPath,
                          immediate: &immediate,
                          deferred: &deferred)
            }
        }
    }
    
    // MARK: - Optimize Fetch Commands
    
    func optimizeFetchCommands(plan: FetchPlan) -> [String] {
        var commands: [String] = []
        
        // Group sections by similar sizes for efficient fetching
        let grouped = groupBySimilarSize(plan.sections)
        
        for group in grouped {
            if group.count == 1 {
                // Single part fetch
                let section = group[0]
                commands.append("FETCH \(section.section)")
            } else {
                // Multiple parts in one command
                let sections = group.map { $0.section }.joined(separator: " ")
                commands.append("FETCH (\(sections))")
            }
        }
        
        return commands
    }
    
    private func groupBySimilarSize(_ sections: [FetchPlan.FetchSection]) -> [[FetchPlan.FetchSection]] {
        // Group sections with similar sizes to optimize network usage
        var groups: [[FetchPlan.FetchSection]] = []
        var currentGroup: [FetchPlan.FetchSection] = []
        var currentSize = 0
        let maxGroupSize = 1024 * 1024  // 1MB per group
        
        for section in sections.sorted(by: { $0.expectedSize < $1.expectedSize }) {
            if currentSize + section.expectedSize > maxGroupSize && !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = [section]
                currentSize = section.expectedSize
            } else {
                currentGroup.append(section)
                currentSize += section.expectedSize
            }
        }
        
        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        
        return groups
    }
}

// MARK: - Partial Fetch Support

extension FetchStrategy {
    
    /// Create partial fetch commands for large attachments
    func createPartialFetchCommands(for section: FetchPlan.FetchSection,
                                   chunkSize: Int = 512 * 1024) -> [String] {
        var commands: [String] = []
        let totalSize = section.expectedSize
        var offset = 0
        
        while offset < totalSize {
            let length = min(chunkSize, totalSize - offset)
            let command = "FETCH \(section.section)<\(offset).\(length)>"
            commands.append(command)
            offset += length
        }
        
        return commands
    }
}
