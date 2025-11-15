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
        analyzePart(bodyStructure,
                   partPath: "",
                   immediate: &immediateSections,
                   deferred: &deferredSections)
        
        return FetchPlan(sections: immediateSections,
                        deferredSections: deferredSections)
    }
    
    // MARK: - Recursive Part Analysis
    
    private func analyzePart(_ part: IMAPBodyStructure,
                           partPath: String,
                           immediate: inout [FetchPlan.FetchSection],
                           deferred: inout [FetchPlan.FetchSection]) {
        
        let currentPath = partPath.isEmpty ? "1" : partPath
        
        switch part {
        case .text(let subtype, let charset):
            // Text parts are usually body candidates
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0, // Size not available in enum
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
            
        case .image(let subtype):
            // Images are usually attachments, fetch later
            let priority: FetchPriority = .deferred
            
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0, // Size not available in enum
                mimeType: "image/\(subtype)",
                priority: priority,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .application(let subtype):
            // Application parts are usually attachments
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0, // Size not available in enum
                mimeType: "application/\(subtype)",
                priority: .deferred,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .message(let subtype):
            // Embedded messages might need special handling
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0, // Size not available in enum
                mimeType: "message/\(subtype)",
                priority: .deferred,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .audio(let subtype):
            // Audio attachments are deferred
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0,
                mimeType: "audio/\(subtype)",
                priority: .skip,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .video(let subtype):
            // Video attachments are deferred  
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0,
                mimeType: "video/\(subtype)",
                priority: .skip,
                isBodyCandidate: false
            )
            deferred.append(section)
            
        case .other(let type, let subtype):
            // Other types are usually attachments
            let section = FetchPlan.FetchSection(
                partId: currentPath,
                section: "BODY[\(currentPath)]",
                expectedSize: 0,
                mimeType: "\(type)/\(subtype)",
                priority: .skip,
                isBodyCandidate: false
            )
            deferred.append(section)
        }
    }
    
    // MARK: - Handle multipart/alternative
    
    private func processAlternative(parts: [IMAPBodyStructure],
                                  basePath: String,
                                  immediate: inout [FetchPlan.FetchSection],
                                  deferred: inout [FetchPlan.FetchSection]) {
        
        // Prefer HTML over plain text
        var bestPart: (index: Int, part: IMAPBodyStructure)?
        
        for (index, part) in parts.enumerated() {
            if case let .text(subtype, _) = part {
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
