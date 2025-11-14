// AILO_APP/Helpers/Processing/BodySelectionHeuristic_Phase7.swift
// PHASE 7: Body Selection Heuristic
// Smart selection of best body part from multipart/alternative and multipart/related

import Foundation

// MARK: - Body Part Candidate

public struct BodyPartCandidate: Sendable {
    public let partId: String
    public let mediaType: String
    public let charset: String?
    public let content: String
    public let quality: Int // Higher = better
    public let isInline: Bool
    public let hasInlineImages: Bool
    
    public init(
        partId: String,
        mediaType: String,
        charset: String?,
        content: String,
        quality: Int,
        isInline: Bool,
        hasInlineImages: Bool
    ) {
        self.partId = partId
        self.mediaType = mediaType
        self.charset = charset
        self.content = content
        self.quality = quality
        self.isInline = isInline
        self.hasInlineImages = hasInlineImages
    }
}

// MARK: - Selection Strategy

public enum BodySelectionStrategy {
    case preferHTML        // Always prefer HTML if available
    case preferPlainText   // Always prefer plain text
    case smart             // Intelligent selection based on content quality
    
    public static let `default`: BodySelectionStrategy = .smart
}

// MARK: - Body Selection Result

public struct BodySelectionResult: Sendable {
    public let selectedPart: BodyPartCandidate
    public let alternativeParts: [BodyPartCandidate]
    public let inlineAttachments: [String] // Content-IDs of required inline images
    public let selectionReason: String
    
    public init(
        selectedPart: BodyPartCandidate,
        alternativeParts: [BodyPartCandidate],
        inlineAttachments: [String],
        selectionReason: String
    ) {
        self.selectedPart = selectedPart
        self.alternativeParts = alternativeParts
        self.inlineAttachments = inlineAttachments
        self.selectionReason = selectionReason
    }
}

// MARK: - Body Selection Heuristic

public class BodySelectionHeuristic {
    
    private let strategy: BodySelectionStrategy
    
    public init(strategy: BodySelectionStrategy = .default) {
        self.strategy = strategy
    }
    
    // MARK: - Main Selection Method
    
    /// Select best body part from candidates
    public func selectBestBody(
        from candidates: [BodyPartCandidate],
        relatedParts: [MIMEPart] = []
    ) -> BodySelectionResult {
        
        print("📊 [BODY-SELECT] Selecting from \(candidates.count) candidates")
        
        guard !candidates.isEmpty else {
            // Fallback: create empty plain text
            let fallback = BodyPartCandidate(
                partId: "1",
                mediaType: "text/plain",
                charset: "utf-8",
                content: "",
                quality: 0,
                isInline: true,
                hasInlineImages: false
            )
            return BodySelectionResult(
                selectedPart: fallback,
                alternativeParts: [],
                inlineAttachments: [],
                selectionReason: "No body candidates available"
            )
        }
        
        // Apply strategy
        let selected: BodyPartCandidate
        let reason: String
        
        switch strategy {
        case .preferHTML:
            (selected, reason) = selectPreferredHTML(from: candidates)
        case .preferPlainText:
            (selected, reason) = selectPreferredPlainText(from: candidates)
        case .smart:
            (selected, reason) = selectSmart(from: candidates)
        }
        
        // Find inline attachments needed by selected part
        let inlineAttachments = extractInlineAttachments(
            from: selected.content,
            availableParts: relatedParts
        )
        
        // Get alternatives (other candidates)
        let alternatives = candidates.filter { $0.partId != selected.partId }
        
        print("✅ [BODY-SELECT] Selected: \(selected.mediaType) - \(reason)")
        
        return BodySelectionResult(
            selectedPart: selected,
            alternativeParts: alternatives,
            inlineAttachments: inlineAttachments,
            selectionReason: reason
        )
    }
    
    // MARK: - Strategy: Prefer HTML
    
    private func selectPreferredHTML(from candidates: [BodyPartCandidate]) -> (BodyPartCandidate, String) {
        // Find first HTML part
        if let html = candidates.first(where: { $0.mediaType.contains("html") }) {
            return (html, "HTML preferred by strategy")
        }
        
        // Fallback to plain text
        if let text = candidates.first(where: { $0.mediaType.contains("plain") }) {
            return (text, "HTML not available, using plain text")
        }
        
        // Last resort: first candidate
        return (candidates[0], "No HTML or plain text, using first candidate")
    }
    
    // MARK: - Strategy: Prefer Plain Text
    
    private func selectPreferredPlainText(from candidates: [BodyPartCandidate]) -> (BodyPartCandidate, String) {
        // Find first plain text part
        if let text = candidates.first(where: { $0.mediaType.contains("plain") }) {
            return (text, "Plain text preferred by strategy")
        }
        
        // Fallback to HTML
        if let html = candidates.first(where: { $0.mediaType.contains("html") }) {
            return (html, "Plain text not available, using HTML")
        }
        
        // Last resort: first candidate
        return (candidates[0], "No plain text or HTML, using first candidate")
    }
    
    // MARK: - Strategy: Smart Selection
    
    private func selectSmart(from candidates: [BodyPartCandidate]) -> (BodyPartCandidate, String) {
        // Calculate quality scores for each candidate
        var scoredCandidates: [(candidate: BodyPartCandidate, score: Int, reason: String)] = []
        
        for candidate in candidates {
            let (score, reason) = calculateQualityScore(for: candidate)
            scoredCandidates.append((candidate, score, reason))
        }
        
        // Sort by score (highest first)
        scoredCandidates.sort { $0.score > $1.score }
        
        // Log scores
        for (candidate, score, reason) in scoredCandidates {
            print("  📊 \(candidate.mediaType): score=\(score) - \(reason)")
        }
        
        // Return best candidate
        let best = scoredCandidates[0]
        return (best.candidate, best.reason)
    }
    
    // MARK: - Quality Scoring
    
    private func calculateQualityScore(for candidate: BodyPartCandidate) -> (score: Int, reason: String) {
        var score = 0
        var reasons: [String] = []
        
        // Base score from pre-calculated quality
        score += candidate.quality * 10
        
        // Media type preference
        if candidate.mediaType.contains("html") {
            score += 100
            reasons.append("HTML content")
            
            // Check for substantial content
            let htmlLength = candidate.content.count
            if htmlLength > 1000 {
                score += 20
                reasons.append("substantial HTML (\(htmlLength) chars)")
            } else if htmlLength > 500 {
                score += 10
                reasons.append("moderate HTML")
            }
            
            // Check for inline images
            if candidate.hasInlineImages {
                score += 15
                reasons.append("has inline images")
            }
            
            // Check for rich formatting
            if hasRichFormatting(html: candidate.content) {
                score += 10
                reasons.append("rich formatting")
            }
            
        } else if candidate.mediaType.contains("plain") {
            score += 50
            reasons.append("plain text")
            
            // Check for meaningful content
            let textLength = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).count
            if textLength > 1000 {
                score += 15
                reasons.append("substantial text")
            } else if textLength > 500 {
                score += 8
                reasons.append("moderate text")
            } else if textLength < 100 {
                score -= 10
                reasons.append("very short text")
            }
            
            // Penalize if it looks like a plain text version of HTML
            if looksLikeHTMLFallback(text: candidate.content) {
                score -= 20
                reasons.append("looks like HTML fallback")
            }
        }
        
        // Charset penalty
        if let charset = candidate.charset?.lowercased() {
            if charset == "utf-8" || charset == "utf8" {
                score += 5
                reasons.append("UTF-8")
            }
        }
        
        // Inline preference
        if candidate.isInline {
            score += 5
        }
        
        let reasonString = reasons.isEmpty ? "default scoring" : reasons.joined(separator: ", ")
        return (score, reasonString)
    }
    
    // MARK: - Content Analysis
    
    /// Check if HTML has rich formatting
    private func hasRichFormatting(html: String) -> Bool {
        let richTags = ["<table", "<img", "<div", "<span", "<style", "<font"]
        return richTags.contains { html.lowercased().contains($0) }
    }
    
    /// Check if plain text looks like HTML fallback (very short or generic)
    private func looksLikeHTMLFallback(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Very short text
        if trimmed.count < 50 {
            return true
        }
        
        // Generic fallback messages
        let fallbackPatterns = [
            "view this email in your browser",
            "please enable html",
            "html version",
            "click here to view"
        ]
        
        let lowerText = trimmed.lowercased()
        return fallbackPatterns.contains { lowerText.contains($0) }
    }
    
    // MARK: - Inline Attachment Extraction
    
    /// Extract Content-IDs of inline attachments referenced in HTML
    private func extractInlineAttachments(
        from htmlContent: String,
        availableParts: [MIMEPart]
    ) -> [String] {
        var contentIds: [String] = []
        
        // Find all cid: references in HTML
        let pattern = "cid:([^\"'\\s>]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return contentIds
        }
        
        let matches = regex.matches(
            in: htmlContent,
            range: NSRange(htmlContent.startIndex..., in: htmlContent)
        )
        
        for match in matches {
            if let range = Range(match.range(at: 1), in: htmlContent) {
                let cid = String(htmlContent[range])
                contentIds.append(cid)
            }
        }
        
        print("📎 [BODY-SELECT] Found \(contentIds.count) inline attachment references")
        
        return contentIds
    }
    
    // MARK: - Multipart Structure Handling
    
    /// Parse multipart/alternative structure
    public static func parseMultipartAlternative(
        parts: [MIMEPart]
    ) -> [BodyPartCandidate] {
        var candidates: [BodyPartCandidate] = []
        
        for part in parts {
            // Only consider text parts as body candidates
            if part.mediaType.hasPrefix("text/") {
                let quality = assessPartQuality(part)
                
                let candidate = BodyPartCandidate(
                    partId: part.partId,
                    mediaType: part.mediaType,
                    charset: part.charset,
                    content: part.body,
                    quality: quality,
                    isInline: part.disposition != "attachment",
                    hasInlineImages: part.body.lowercased().contains("cid:")
                )
                
                candidates.append(candidate)
            }
        }
        
        return candidates
    }
    
    /// Assess quality of MIME part
    private static func assessPartQuality(_ part: MIMEPart) -> Int {
        var quality = 5 // Base quality
        
        // Content length
        if part.body.count > 1000 {
            quality += 2
        }
        
        // Media type
        if part.mediaType.contains("html") {
            quality += 3
        }
        
        // Charset
        if let charset = part.charset?.lowercased(),
           charset == "utf-8" || charset == "utf8" {
            quality += 1
        }
        
        return quality
    }
    
    // MARK: - Multipart/Related Handling
    
    /// Find root part in multipart/related
    public static func findRootPart(in parts: [MIMEPart]) -> MIMEPart? {
        // First, look for part with start parameter in Content-Type
        // Then, look for first text/html part
        // Finally, first text part
        
        return parts.first { $0.mediaType.contains("html") } ??
               parts.first { $0.mediaType.hasPrefix("text/") } ??
               parts.first
    }
}

// MARK: - Usage Documentation

/*
 BODY SELECTION HEURISTIC (Phase 7)
 ===================================
 
 BASIC USAGE:
 ```swift
 let heuristic = BodySelectionHeuristic(strategy: .smart)
 
 let candidates = BodySelectionHeuristic.parseMultipartAlternative(
     parts: mimeParts
 )
 
 let result = heuristic.selectBestBody(
     from: candidates,
     relatedParts: inlineParts
 )
 
 print("Selected: \(result.selectedPart.mediaType)")
 print("Reason: \(result.selectionReason)")
 print("Inline attachments: \(result.inlineAttachments)")
 ```
 
 STRATEGIES:
 ```swift
 // Always prefer HTML
 let htmlPref = BodySelectionHeuristic(strategy: .preferHTML)
 
 // Always prefer plain text
 let textPref = BodySelectionHeuristic(strategy: .preferPlainText)
 
 // Smart selection (default)
 let smart = BodySelectionHeuristic(strategy: .smart)
 ```
 
 MULTIPART/RELATED:
 ```swift
 // Find root part in multipart/related
 if let root = BodySelectionHeuristic.findRootPart(in: parts) {
     print("Root: \(root.mediaType)")
 }
 ```
 
 QUALITY SCORING:
 Smart strategy considers:
 - Media type (HTML > plain text)
 - Content length (substantial > short)
 - Rich formatting (tables, images, styles)
 - Inline images presence
 - Charset (UTF-8 preferred)
 - Fallback detection (generic messages)
 
 TYPICAL STRUCTURES:
 
 multipart/alternative:
   text/plain     <- fallback
   text/html      <- preferred (rich content)
 
 multipart/related:
   multipart/alternative:
     text/plain
     text/html    <- root part
   image/png      <- inline attachment (cid:...)
   image/jpeg     <- inline attachment
 
 INLINE ATTACHMENTS:
 - Automatically extracts cid: references from HTML
 - Returns Content-IDs needed for display
 - Use with AttachmentServingService to resolve URLs
 
 EXAMPLE RESULT:
 ```swift
 BodySelectionResult(
     selectedPart: BodyPartCandidate(
         mediaType: "text/html",
         quality: 8,
         hasInlineImages: true
     ),
     alternativeParts: [plain text candidate],
     inlineAttachments: ["image001@example.com", "logo@company.com"],
     selectionReason: "HTML content, substantial HTML, has inline images"
 )
 ```
 */
