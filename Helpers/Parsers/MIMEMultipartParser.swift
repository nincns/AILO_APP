// MIMEMultipartParser.swift - Enhanced MIME multipart parsing with robust boundary detection
import Foundation

/// Enhanced MIME multipart parser with improved boundary detection and part extraction
public class MIMEMultipartParser {
    
    /// Represents a single MIME part
    public struct MIMEPart {
        public let headers: [String: String]
        public let content: String
        public let contentType: String?
        public let charset: String?
        public let transferEncoding: String?
        public let isHTML: Bool
        
        public init(headers: [String: String], content: String) {
            self.headers = headers
            self.content = content
            self.contentType = headers["content-type"]
            self.charset = MIMEMultipartParser.extractCharset(from: headers["content-type"])
            self.transferEncoding = headers["content-transfer-encoding"]
            self.isHTML = headers["content-type"]?.lowercased().contains("text/html") ?? false
        }
    }
    
    /// Parse multipart content with enhanced boundary detection
    public static func parseMultipart(_ content: String, boundary: String) -> [MIMEPart] {
        // Step 1: Robust boundary detection
        let detectedBoundaries = detectAllBoundaries(in: content, primaryBoundary: boundary)
        
        // Step 2: Split content by boundaries
        let parts = extractParts(from: content, boundaries: detectedBoundaries)
        
        // Step 3: Parse each part (headers + content)
        return parts.compactMap { parsePart($0) }
    }
    
    /// Detect all boundary variations in content
    private static func detectAllBoundaries(in content: String, primaryBoundary: String) -> [String] {
        var boundaries: [String] = []
        
        // Add primary boundary variants
        boundaries.append("--" + primaryBoundary)
        boundaries.append("--" + primaryBoundary + "--") // Final boundary
        
        // Detect additional boundaries from content
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Look for boundary-like patterns
            if trimmed.hasPrefix("--") && 
               (trimmed.contains("_") || trimmed.contains("-") || trimmed.contains("=")) &&
               trimmed.count > 10 &&
               !trimmed.contains(" ") {
                
                // Additional validation: should be similar to primary boundary
                if isSimilarBoundary(trimmed, to: primaryBoundary) {
                    boundaries.append(trimmed)
                }
            }
        }
        
        return Array(Set(boundaries)) // Remove duplicates
    }
    
    /// Check if detected boundary is similar to primary boundary
    private static func isSimilarBoundary(_ candidate: String, to primary: String) -> Bool {
        let cleanCandidate = candidate.replacingOccurrences(of: "--", with: "")
        let cleanPrimary = primary
        
        // Must share some common substring
        if cleanCandidate.count > 5 && cleanPrimary.count > 5 {
            let candidateChars = Set(cleanCandidate)
            let primaryChars = Set(cleanPrimary)
            let intersection = candidateChars.intersection(primaryChars)
            
            // At least 70% character overlap
            let similarity = Double(intersection.count) / Double(primaryChars.count)
            return similarity > 0.7
        }
        
        return false
    }
    
    /// Extract parts from content using detected boundaries
    private static func extractParts(from content: String, boundaries: [String]) -> [String] {
        var parts: [String] = []
        let lines = content.components(separatedBy: .newlines)
        
        var currentPart: [String] = []
        var inPart = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if this line is a boundary
            let isBoundary = boundaries.contains { boundary in
                trimmed == boundary || trimmed.hasPrefix(boundary)
            }
            
            if isBoundary {
                // End current part and start new one
                if inPart && !currentPart.isEmpty {
                    parts.append(currentPart.joined(separator: "\n"))
                }
                currentPart = []
                
                // Don't start new part if this is final boundary
                inPart = !trimmed.hasSuffix("--")
            } else if inPart {
                currentPart.append(line)
            }
        }
        
        // Add final part if exists
        if inPart && !currentPart.isEmpty {
            parts.append(currentPart.joined(separator: "\n"))
        }
        
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    
    /// Parse individual part (headers + content)
    private static func parsePart(_ partContent: String) -> MIMEPart? {
        let lines = partContent.components(separatedBy: .newlines)
        
        // Find the separator between headers and content (empty line)
        var headerEndIndex = 0
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headerEndIndex = index
                break
            }
        }
        
        // Extract headers
        let headerLines = Array(lines[0..<headerEndIndex])
        let headers = parseHeaders(headerLines)
        
        // Extract content (everything after empty line)
        let contentLines = Array(lines[(headerEndIndex + 1)...])
        let content = contentLines.joined(separator: "\n")
        
        // Decode content if needed
        let decodedContent = decodePartContent(content, headers: headers)
        
        return MIMEPart(headers: headers, content: decodedContent)
    }
    
    /// Parse headers from lines
    private static func parseHeaders(_ headerLines: [String]) -> [String: String] {
        var headers: [String: String] = [:]
        var currentHeader = ""
        var currentValue = ""
        
        for line in headerLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                continue
            }
            
            // Check if this is a continuation line (starts with space/tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                // Continuation of previous header
                currentValue += " " + trimmed
            } else {
                // New header - save previous if exists
                if !currentHeader.isEmpty && !currentValue.isEmpty {
                    headers[currentHeader.lowercased()] = currentValue
                }
                
                // Parse new header
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    currentHeader = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    currentValue = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Save final header
        if !currentHeader.isEmpty && !currentValue.isEmpty {
            headers[currentHeader.lowercased()] = currentValue
        }
        
        return headers
    }
    
    /// Decode part content based on transfer encoding (enhanced with TransferEncodingDecoder)
    private static func decodePartContent(_ content: String, headers: [String: String]) -> String {
        let transferEncoding = headers["content-transfer-encoding"]
        let charset = extractCharset(from: headers["content-type"])
        
        // Use the comprehensive TransferEncodingDecoder
        return TransferEncodingDecoder.decode(content, encoding: transferEncoding, charset: charset)
    }
    
    /// Extract charset from Content-Type header (enhanced with HeaderCharsetDetector)
    public static func extractCharset(from contentType: String?) -> String? {
        return HeaderCharsetDetector.extractCharset(from: contentType)
    }
    
    /// Select best part from multipart/alternative
    public static func selectBestPart(from parts: [MIMEPart]) -> MIMEPart? {
        // Priority: HTML > Plain Text > Other
        
        // First, try to find HTML part
        if let htmlPart = parts.first(where: { $0.isHTML }) {
            return htmlPart
        }
        
        // Then, try to find plain text part
        if let textPart = parts.first(where: { 
            $0.contentType?.lowercased().contains("text/plain") == true 
        }) {
            return textPart
        }
        
        // Fallback: return first non-empty part
        return parts.first { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    
    /// Test method for validation
    public static func test() {
        print("🧪 Testing MIMEMultipartParser...")
        
        let testContent = """
        --Apple-Mail=_B4054DC1-A4FD-4320-9DFD-9CA26B3CF4FE
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable
        
        This is the plain text version with =E4 umlaut.
        --Apple-Mail=_B4054DC1-A4FD-4320-9DFD-9CA26B3CF4FE
        Content-Type: text/html; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable
        
        <p>This is the <b>HTML</b> version with =E4 umlaut.</p>
        --Apple-Mail=_B4054DC1-A4FD-4320-9DFD-9CA26B3CF4FE--
        """
        
        let parts = parseMultipart(testContent, boundary: "Apple-Mail=_B4054DC1-A4FD-4320-9DFD-9CA26B3CF4FE")
        
        print("Found \(parts.count) parts")
        for (index, part) in parts.enumerated() {
            print("Part \(index + 1): \(part.contentType ?? "unknown"), HTML: \(part.isHTML)")
            print("Content: \(part.content.prefix(50))...")
        }
        
        if let bestPart = selectBestPart(from: parts) {
            print("Best part: \(bestPart.contentType ?? "unknown")")
        }
        
        print("✅ MIMEMultipartParser tests completed")
    }
}