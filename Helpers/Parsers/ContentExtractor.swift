// ContentExtractor.swift - Utility for extracting readable content from emails
import Foundation

/// Utility class for extracting readable content from email text
public class ContentExtractor {
    
    /// Extract readable content with rendered text detection - keeps formatted version
    public static func extractReadableContentWithRenderedTextDetection(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        
        // Strategy 1: Look for RAW text followed by rendered text pattern
        if let renderedContent = detectAndExtractRenderedText(lines) {
            return renderedContent
        }
        
        // Strategy 2: Fall back to regular content extraction
        return extractReadableContent(content)
    }
    
    /// Detect and extract rendered text (the formatted version after RAW)
    public static func detectAndExtractRenderedText(_ lines: [String]) -> String? {
        var potentialSections: [(startIndex: Int, endIndex: Int, quality: Double)] = []
        let minSectionLength = 5 // Minimum lines for a section
        
        // Find content sections by analyzing text similarity and quality
        var currentSection: [String] = []
        var sectionStart = 0
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip technical lines
            if ContentAnalyzer.isClearlyTechnical(trimmed) {
                if currentSection.count >= minSectionLength {
                    let quality = ContentAnalyzer.evaluateTextQuality(currentSection)
                    potentialSections.append((
                        startIndex: sectionStart,
                        endIndex: index - 1,
                        quality: quality
                    ))
                }
                currentSection = []
                sectionStart = index + 1
                continue
            }
            
            // Add to current section
            currentSection.append(trimmed)
            if currentSection.count == 1 {
                sectionStart = index
            }
        }
        
        // Add final section if valid
        if currentSection.count >= minSectionLength {
            let quality = ContentAnalyzer.evaluateTextQuality(currentSection)
            potentialSections.append((
                startIndex: sectionStart,
                endIndex: lines.count - 1,
                quality: quality
            ))
        }
        
        // If we have multiple sections, compare them for duplicates
        if potentialSections.count >= 2 {
            return selectBestRenderedSection(potentialSections, lines: lines)
        }
        
        return nil
    }
    
    /// Select the best rendered section from multiple candidates
    public static func selectBestRenderedSection(_ sections: [(startIndex: Int, endIndex: Int, quality: Double)], lines: [String]) -> String {
        // Sort by quality, prefer later sections if quality is similar (rendered text usually comes later)
        let sortedSections = sections.sorted { section1, section2 in
            let qualityDiff = abs(section1.quality - section2.quality)
            
            // If quality is very similar (within 20%), prefer the later section
            if qualityDiff < 20.0 {
                return section1.startIndex < section2.startIndex
            }
            
            return section1.quality < section2.quality
        }
        
        guard let bestSection = sortedSections.last else {
            return lines.joined(separator: "\n")
        }
        
        // Extract the best section
        let sectionLines = Array(lines[bestSection.startIndex...bestSection.endIndex])
        
        // Check for obvious content duplication between sections
        if sections.count >= 2 {
            let bestContent = sectionLines.joined(separator: "\n")
            
            // Remove any remaining duplicated content from earlier sections
            return removeDuplicatedContentFromEarlierSections(bestContent, allSections: sections, lines: lines, selectedIndex: bestSection.startIndex)
        }
        
        return sectionLines.joined(separator: "\n")
    }
    
    /// Remove content that appears to be duplicated from earlier sections
    public static func removeDuplicatedContentFromEarlierSections(_ bestContent: String, allSections: [(startIndex: Int, endIndex: Int, quality: Double)], lines: [String], selectedIndex: Int) -> String {
        let bestLines = bestContent.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        
        for line in bestLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Always keep short lines and empty lines (formatting)
            if trimmed.isEmpty || trimmed.count <= 10 {
                cleanedLines.append(line)
                continue
            }
            
            // Check if this line appears in earlier sections (indicating it might be duplicated RAW content)
            var appearsInEarlierSection = false
            
            for section in allSections {
                if section.startIndex >= selectedIndex {
                    continue // Only check earlier sections
                }
                
                let sectionText = Array(lines[section.startIndex...section.endIndex]).joined(separator: "\n")
                
                // Use similarity check rather than exact match
                if ContentAnalyzer.isContentSimilar(trimmed, to: sectionText) {
                    appearsInEarlierSection = true
                    break
                }
            }
            
            // Keep the line if it doesn't appear to be duplicated raw content
            if !appearsInEarlierSection {
                cleanedLines.append(line)
            }
        }
        
        return cleanedLines.joined(separator: "\n")
    }
    
    /// Extract readable content intelligently, avoiding technical noise (fallback method)
    public static func extractReadableContent(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        
        // Find potential content sections
        var contentSections: [(startIndex: Int, quality: Int)] = []
        
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip obviously technical lines
            if ContentAnalyzer.isClearlyTechnical(line) || line.isEmpty {
                continue
            }
            
            // Look ahead to evaluate content quality
            let qualityScore = ContentAnalyzer.evaluateContentQuality(lines, startingAt: i)
            
            if qualityScore > 8 { // Lowered threshold for better content detection
                contentSections.append((startIndex: i, quality: qualityScore))
            }
        }
        
        // If we found good content sections, use the best one
        if let bestSection = contentSections.max(by: { $0.quality < $1.quality }) {
            let startIndex = bestSection.startIndex
            
            // Find the end of this content section more intelligently
            var endIndex = lines.count
            var technicalLineCount = 0
            
            for i in (startIndex + 1)..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Stop at clear boundaries
                if line.hasPrefix("--Apple-Mail=") || 
                   line.hasPrefix("--=_NextPart_") ||
                   (line.contains("Content-Type:") && line.contains("boundary=")) {
                    endIndex = i
                    break
                }
                
                // Stop if we encounter too many technical lines in a row
                if ContentAnalyzer.isClearlyTechnical(line) {
                    technicalLineCount += 1
                    if technicalLineCount >= 3 {
                        endIndex = i - 2 // Go back before technical section
                        break
                    }
                } else {
                    technicalLineCount = 0
                }
            }
            
            let extractedContent = Array(lines[startIndex..<endIndex]).joined(separator: "\n")
            
            // Sanity check: make sure we haven't extracted something too technical
            if ContentAnalyzer.hasReasonableTextDensity(extractedContent) && extractedContent.count > 20 {
                return extractedContent
            }
        }
        
        // Fallback: clean the original content more conservatively
        return removeOnlyObviousTechnicalLines(content)
    }
    
    /// Remove only obvious technical lines, preserve everything else
    public static func removeOnlyObviousTechnicalLines(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var cleanLines: [String] = []
        
        for line in lines {
            if !ContentAnalyzer.isClearlyTechnical(line) {
                cleanLines.append(line)
            }
        }
        
        return cleanLines.joined(separator: "\n")
    }
    
    /// Advanced boundary detection for multipart content
    public static func detectContentBoundaries(_ content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var boundaries: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Detect Apple Mail boundaries
            if trimmed.hasPrefix("--Apple-Mail=") {
                boundaries.append(trimmed)
            }
            
            // Detect generic MIME boundaries
            if trimmed.hasPrefix("--") && trimmed.contains("_") && trimmed.count > 10 {
                boundaries.append(trimmed)
            }
            
            // Extract boundary from Content-Type headers
            if trimmed.contains("boundary=") {
                let components = trimmed.components(separatedBy: "boundary=")
                if components.count > 1 {
                    let boundary = components[1]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
                        .components(separatedBy: CharacterSet.whitespacesAndNewlines)[0]
                    if !boundary.isEmpty {
                        boundaries.append("--" + boundary)
                    }
                }
            }
        }
        
        return Array(Set(boundaries)) // Remove duplicates
    }
    
    /// Validate that extracted content is reasonable and readable
    public static func validateExtractedContent(_ content: String, originalContent: String) -> Bool {
        let extractedWordCount = ContentAnalyzer.countWords(in: content)
        let originalWordCount = ContentAnalyzer.countWords(in: originalContent)
        
        // Extracted content should have reasonable word count
        if extractedWordCount < 5 {
            return false // Too little content
        }
        
        // Extracted content shouldn't be way longer than original
        if extractedWordCount > originalWordCount * 2 {
            return false // Something went wrong
        }
        
        // Check for reasonable text density
        return ContentAnalyzer.hasReasonableTextDensity(content)
    }
}