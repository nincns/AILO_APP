// ContentAnalyzer.swift - Utility class for analyzing and evaluating email content
import Foundation

/// Utility class for analyzing email content quality, structure, and characteristics
public class ContentAnalyzer {
    
    // MARK: - HTML Detection
    
    /// Detect if content contains HTML markup
    public static func detectHTMLContent(_ content: String) -> Bool {
        let lowercased = content.lowercased()
        
        // Check for common HTML tags
        let htmlPatterns = [
            "<html", "</html>",
            "<body", "</body>",
            "<div", "</div>",
            "<p>", "</p>",
            "<br>", "<br/>", "<br />",
            "<span", "</span>",
            "<table", "</table>",
            "<tr>", "</tr>",
            "<td>", "</td>",
            "<img", "<a href",
            "<strong>", "</strong>",
            "<em>", "</em>",
            "<ul>", "</ul>",
            "<li>", "</li>"
        ]
        
        for pattern in htmlPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }
        
        // Check for HTML entities
        let entityPattern = /&[a-zA-Z][a-zA-Z0-9]*;|&#[0-9]+;|&#x[0-9a-fA-F]+;/
        if content.contains(entityPattern) {
            return true
        }
        
        return false
    }
    
    // MARK: - Content Quality Analysis
    
    /// Check if content has reasonable text density (not just technical noise)
    public static func hasReasonableTextDensity(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        guard nonEmptyLines.count > 0 else { return false }
        
        let totalChars = content.count
        let wordCount = countWords(in: content)
        let technicalLineCount = nonEmptyLines.filter { isClearlyTechnical($0) }.count
        
        // Basic metrics
        let averageWordsPerLine = Double(wordCount) / Double(nonEmptyLines.count)
        let technicalRatio = Double(technicalLineCount) / Double(nonEmptyLines.count)
        let charToWordRatio = totalChars > 0 ? Double(totalChars) / Double(max(wordCount, 1)) : 0
        
        // Content should have:
        // - At least some words per line on average
        // - Not be mostly technical lines
        // - Have reasonable character-to-word ratio (not too much noise)
        return averageWordsPerLine > 0.5 && 
               technicalRatio < 0.8 && 
               charToWordRatio < 50.0 && 
               wordCount > 3
    }
    
    /// Evaluate text quality of a section
    public static func evaluateTextQuality(_ lines: [String]) -> Double {
        guard !lines.isEmpty else { return 0.0 }
        
        let content = lines.joined(separator: "\n")
        let wordCount = countWords(in: content)
        let technicalCount = lines.filter { isClearlyTechnical($0) }.count
        let nonEmptyCount = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        
        guard nonEmptyCount > 0 else { return 0.0 }
        
        // Calculate quality score (0-100)
        let wordDensity = Double(wordCount) / Double(nonEmptyCount) * 10.0 // Words per non-empty line
        let technicalPenalty = Double(technicalCount) / Double(nonEmptyCount) * 50.0 // Penalty for technical lines
        let lengthBonus = min(Double(wordCount) / 10.0, 20.0) // Bonus for having substantial content
        
        return max(0.0, wordDensity + lengthBonus - technicalPenalty)
    }
    
    /// Evaluate content quality starting from a specific line
    public static func evaluateContentQuality(_ lines: [String], startingAt index: Int) -> Int {
        let maxLinesToCheck = 20
        let endIndex = min(index + maxLinesToCheck, lines.count)
        
        guard index < lines.count else { return 0 }
        
        let sectionLines = Array(lines[index..<endIndex])
        let quality = evaluateTextQuality(sectionLines)
        
        return Int(quality)
    }
    
    // MARK: - Technical Content Detection
    
    /// Check if a line is clearly technical (headers, boundaries, etc.)
    public static func isClearlyTechnical(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty lines are not technical
        if trimmed.isEmpty {
            return false
        }
        
        // MIME boundaries
        if trimmed.hasPrefix("--") && (trimmed.contains("Apple-Mail") || trimmed.contains("_NextPart_") || trimmed.contains("boundary")) {
            return true
        }
        
        // Email headers
        let headerPatterns = [
            "Content-Type:", "Content-Transfer-Encoding:", "Content-Disposition:",
            "Message-ID:", "Date:", "From:", "To:", "Subject:", "Reply-To:",
            "Return-Path:", "Received:", "X-", "MIME-Version:",
            "Content-ID:", "Content-Location:", "Content-Base:"
        ]
        
        for pattern in headerPatterns {
            if trimmed.hasPrefix(pattern) {
                return true
            }
        }
        
        // Base64 or quoted-printable encoded content (long strings without spaces)
        if trimmed.count > 50 && !trimmed.contains(" ") && trimmed.allSatisfy({ $0.isLetter || $0.isNumber || "=+/".contains($0) }) {
            return true
        }
        
        // Lines that are mostly special characters or numbers
        let specialCharCount = trimmed.filter { !$0.isLetter && !$0.isWhitespace }.count
        if Double(specialCharCount) / Double(trimmed.count) > 0.7 {
            return true
        }
        
        return false
    }
    
    // MARK: - Content Similarity
    
    /// Check if two content strings are similar (for duplicate detection)
    public static func isContentSimilar(_ content1: String, to content2: String) -> Bool {
        let words1 = Set(content1.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let words2 = Set(content2.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        
        guard !words1.isEmpty && !words2.isEmpty else { return false }
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        let similarity = Double(intersection.count) / Double(union.count)
        return similarity > 0.6 // 60% similarity threshold
    }
    
    // MARK: - Utility Functions
    
    /// Count words in text content
    public static func countWords(in content: String) -> Int {
        let words = content.components(separatedBy: .whitespacesAndNewlines)
        return words.filter { !$0.isEmpty && $0.count > 1 }.count
    }
    
    /// Check if content appears to be mostly readable text
    public static func isReadableText(_ content: String) -> Bool {
        let wordCount = countWords(in: content)
        let lines = content.components(separatedBy: .newlines)
        let technicalLineCount = lines.filter { isClearlyTechnical($0) }.count
        
        // Must have reasonable amount of words and low technical line ratio
        return wordCount > 5 && Double(technicalLineCount) / Double(max(lines.count, 1)) < 0.5
    }
    
    /// Detect if content is primarily structured data vs readable text
    public static func isStructuredData(_ content: String) -> Bool {
        let lines = content.components(separatedBy: .newlines)
        let structuredPatterns = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.contains(":") && !trimmed.contains(" ")
        }
        
        return Double(structuredPatterns.count) / Double(max(lines.count, 1)) > 0.6
    }
}