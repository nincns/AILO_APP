// BodySelectionHeuristic.swift
// Intelligente Heuristik zur Auswahl des besten Email-Body-Parts
// Phase 7: Advanced body selection logic

import Foundation

// MARK: - Body Selection Heuristic

class BodySelectionHeuristic {
    
    // Preference scores for different content types
    private let typePreferences: [String: Int] = [
        "text/html": 100,
        "text/plain": 50,
        "text/enriched": 40,
        "text/rtf": 30
    ]
    
    // MARK: - Select Best Body
    
    func selectBestBody(from parts: [MimePartEntity]) -> MimePartEntity? {
        // Filter for body candidates
        let candidates = parts.filter { $0.isBodyCandidate }
        
        if candidates.isEmpty {
            return nil
        }
        
        // Group by parent for multipart/alternative handling
        let grouped = groupByParent(candidates)
        
        // Process each group
        var bestParts: [MimePartEntity] = []
        
        for (parentId, groupParts) in grouped {
            if let parent = parts.first(where: { $0.partId == parentId }),
               parent.mediaType.contains("alternative") {
                // For multipart/alternative, select the best alternative
                if let best = selectBestAlternative(from: groupParts) {
                    bestParts.append(best)
                }
            } else {
                // For other multiparts, keep all body parts
                bestParts.append(contentsOf: groupParts)
            }
        }
        
        // Final selection from all candidates
        return selectFinalBody(from: bestParts)
    }
    
    // MARK: - Multipart/Alternative Selection
    
    private func selectBestAlternative(from parts: [MimePartEntity]) -> MimePartEntity? {
        // Sort by preference score
        let sorted = parts.sorted { part1, part2 in
            let score1 = typePreferences[part1.mediaType] ?? 0
            let score2 = typePreferences[part2.mediaType] ?? 0
            
            if score1 != score2 {
                return score1 > score2
            }
            
            // If same score, prefer larger content (likely more complete)
            return part1.sizeOctets > part2.sizeOctets
        }
        
        return sorted.first
    }
    
    // MARK: - Final Body Selection
    
    private func selectFinalBody(from parts: [MimePartEntity]) -> MimePartEntity? {
        // If only one part, return it
        if parts.count == 1 {
            return parts.first
        }
        
        // Score each part
        let scored = parts.map { part -> (part: MimePartEntity, score: Int) in
            var score = 0
            
            // Type preference
            score += typePreferences[part.mediaType] ?? 0
            
            // Bonus for non-empty content
            if part.sizeOctets > 0 {
                score += 10
            }
            
            // Bonus for reasonable size (not too small, not too large)
            if part.sizeOctets > 100 && part.sizeOctets < 1_000_000 {
                score += 5
            }
            
            // Penalty for very large parts
            if part.sizeOctets > 10_000_000 {
                score -= 20
            }
            
            // Bonus for UTF-8 charset
            if part.charset?.lowercased() == "utf-8" {
                score += 5
            }
            
            return (part, score)
        }
        
        // Return highest scoring part
        return scored.max(by: { $0.score < $1.score })?.part
    }
    
    // MARK: - Helper Methods
    
    private func groupByParent(_ parts: [MimePartEntity]) -> [String?: [MimePartEntity]] {
        return Dictionary(grouping: parts) { $0.parentPartId }
    }
    
    // MARK: - Advanced Selection for Complex Structures
    
    func selectBodyForDisplay(from message: ParsedMessage) -> BodySelection {
        let allParts = message.mimeParts
        
        // Handle different message structures
        if let rootPart = allParts.first(where: { $0.partId == "1" }) {
            return processMessageStructure(rootPart: rootPart, allParts: allParts)
        }
        
        // Fallback to simple selection
        let selected = selectBestBody(from: allParts)
        return BodySelection(
            primaryBody: selected,
            alternativeBodies: [],
            inlineAttachments: []
        )
    }
    
    private func processMessageStructure(rootPart: MimePartEntity,
                                        allParts: [MimePartEntity]) -> BodySelection {
        
        let mediaType = rootPart.mediaType.lowercased()
        
        switch mediaType {
        case let type where type.contains("multipart/mixed"):
            return processMixedMultipart(rootPart: rootPart, allParts: allParts)
            
        case let type where type.contains("multipart/alternative"):
            return processAlternativeMultipart(rootPart: rootPart, allParts: allParts)
            
        case let type where type.contains("multipart/related"):
            return processRelatedMultipart(rootPart: rootPart, allParts: allParts)
            
        case let type where type.contains("multipart/signed"):
            return processSignedMultipart(rootPart: rootPart, allParts: allParts)
            
        default:
            // Simple message
            return BodySelection(
                primaryBody: rootPart.isBodyCandidate ? rootPart : nil,
                alternativeBodies: [],
                inlineAttachments: []
            )
        }
    }
    
    private func processMixedMultipart(rootPart: MimePartEntity,
                                      allParts: [MimePartEntity]) -> BodySelection {
        // multipart/mixed: first part is usually the body
        let children = allParts.filter { $0.parentPartId == rootPart.partId }
        let bodyCandidates = children.filter { $0.isBodyCandidate }
        
        let primaryBody = bodyCandidates.first
        let attachments = children.filter { !$0.isBodyCandidate }
        
        return BodySelection(
            primaryBody: primaryBody,
            alternativeBodies: Array(bodyCandidates.dropFirst()),
            inlineAttachments: attachments.filter { $0.contentId != nil }
        )
    }
    
    private func processAlternativeMultipart(rootPart: MimePartEntity,
                                            allParts: [MimePartEntity]) -> BodySelection {
        // multipart/alternative: choose best format
        let children = allParts.filter { $0.parentPartId == rootPart.partId }
        let best = selectBestAlternative(from: children)
        
        return BodySelection(
            primaryBody: best,
            alternativeBodies: children.filter { $0.partId != best?.partId },
            inlineAttachments: []
        )
    }
    
    private func processRelatedMultipart(rootPart: MimePartEntity,
                                        allParts: [MimePartEntity]) -> BodySelection {
        // multipart/related: first part is body, rest are inline attachments
        let children = allParts.filter { $0.parentPartId == rootPart.partId }
        
        var primaryBody: MimePartEntity?
        var inlineAttachments: [MimePartEntity] = []
        
        for (index, child) in children.enumerated() {
            if index == 0 {
                // First part is the primary content
                if child.mediaType.contains("multipart/alternative") {
                    // Nested alternative
                    let subChildren = allParts.filter { $0.parentPartId == child.partId }
                    primaryBody = selectBestAlternative(from: subChildren)
                } else {
                    primaryBody = child
                }
            } else {
                // Rest are inline attachments
                if child.contentId != nil {
                    inlineAttachments.append(child)
                }
            }
        }
        
        return BodySelection(
            primaryBody: primaryBody,
            alternativeBodies: [],
            inlineAttachments: inlineAttachments
        )
    }
    
    private func processSignedMultipart(rootPart: MimePartEntity,
                                       allParts: [MimePartEntity]) -> BodySelection {
        // multipart/signed: first part is content, second is signature
        let children = allParts.filter { $0.parentPartId == rootPart.partId }
        
        if let firstPart = children.first {
            // Process the signed content (might be another multipart)
            if firstPart.mediaType.contains("multipart") {
                return processMessageStructure(rootPart: firstPart, allParts: allParts)
            } else {
                return BodySelection(
                    primaryBody: firstPart.isBodyCandidate ? firstPart : nil,
                    alternativeBodies: [],
                    inlineAttachments: []
                )
            }
        }
        
        return BodySelection(primaryBody: nil, alternativeBodies: [], inlineAttachments: [])
    }
}

// MARK: - Body Selection Result

struct BodySelection {
    let primaryBody: MimePartEntity?
    let alternativeBodies: [MimePartEntity]
    let inlineAttachments: [MimePartEntity]
    
    var hasContent: Bool {
        return primaryBody != nil
    }
    
    var requiresInlineProcessing: Bool {
        return !inlineAttachments.isEmpty
    }
}

// MARK: - Body Quality Assessment

extension BodySelectionHeuristic {
    
    func assessBodyQuality(_ part: MimePartEntity) -> BodyQuality {
        var score = 0
        var issues: [String] = []
        
        // Check size
        if part.sizeOctets == 0 {
            issues.append("Empty content")
            score -= 50
        } else if part.sizeOctets < 10 {
            issues.append("Very small content")
            score -= 20
        } else if part.sizeOctets > 10_000_000 {
            issues.append("Very large content")
            score -= 10
        } else {
            score += 20
        }
        
        // Check media type
        if typePreferences[part.mediaType] != nil {
            score += typePreferences[part.mediaType]!
        } else {
            issues.append("Unknown media type")
            score -= 10
        }
        
        // Check charset
        if let charset = part.charset?.lowercased() {
            switch charset {
            case "utf-8":
                score += 10
            case "iso-8859-1", "windows-1252":
                score += 5
            default:
                issues.append("Unusual charset: \(charset)")
            }
        }
        
        // Check encoding
        if let encoding = part.transferEncoding?.lowercased() {
            switch encoding {
            case "base64", "quoted-printable", "7bit", "8bit":
                score += 5
            case "binary":
                // OK but not ideal for body
                break
            default:
                issues.append("Unusual encoding: \(encoding)")
                score -= 5
            }
        }
        
        let quality: BodyQualityLevel
        if score >= 80 {
            quality = .excellent
        } else if score >= 50 {
            quality = .good
        } else if score >= 20 {
            quality = .acceptable
        } else {
            quality = .poor
        }
        
        return BodyQuality(
            level: quality,
            score: score,
            issues: issues
        )
    }
}

// MARK: - Supporting Types

struct BodyQuality {
    let level: BodyQualityLevel
    let score: Int
    let issues: [String]
}

enum BodyQualityLevel {
    case excellent
    case good
    case acceptable
    case poor
}

struct ParsedMessage {
    let mimeParts: [MimePartEntity]
    let bodyParts: [String: Data]
    let attachments: [AttachmentInfo]
    let hasAttachments: Bool
}

struct AttachmentInfo {
    let part: MimePartEntity
}
