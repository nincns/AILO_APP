// TextEnrichedDecoder.swift - Handles text/enriched format conversion
import Foundation

/// Decoder for text/enriched format (RFC 1896) with conversion to HTML
public class TextEnrichedDecoder {
    
    /// Decode text/enriched content and convert to HTML
    public static func decodeToHTML(_ content: String) -> String {
        let decoder = TextEnrichedDecoder()
        return decoder.convertToHTML(content)
    }
    
    /// Decode text/enriched content to plain text (strip formatting)
    public static func decodeToPlainText(_ content: String) -> String {
        let decoder = TextEnrichedDecoder()
        return decoder.convertToPlainText(content)
    }
    
    /// Check if content is text/enriched format
    public static func isTextEnriched(_ content: String) -> Bool {
        // Look for text/enriched specific tags
        let enrichedTags = ["<bold>", "<italic>", "<underline>", "<fontfamily>", 
                           "<color>", "<param>", "<excerpt>", "<smaller>", "<bigger>"]
        
        for tag in enrichedTags {
            if content.lowercased().contains(tag) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Private Implementation
    
    /// Mapping of text/enriched tags to HTML equivalents
    private let tagMapping: [String: (open: String, close: String)] = [
        "bold": (open: "<strong>", close: "</strong>"),
        "italic": (open: "<em>", close: "</em>"),
        "underline": (open: "<u>", close: "</u>"),
        "fixed": (open: "<tt>", close: "</tt>"),
        "smaller": (open: "<small>", close: "</small>"),
        "bigger": (open: "<big>", close: "</big>"),
        "excerpt": (open: "<blockquote>", close: "</blockquote>"),
        "center": (open: "<div align=\"center\">", close: "</div>"),
        "flushleft": (open: "<div align=\"left\">", close: "</div>"),
        "flushright": (open: "<div align=\"right\">", close: "</div>"),
        "flushboth": (open: "<div align=\"justify\">", close: "</div>"),
        "nofill": (open: "<pre>", close: "</pre>")
    ]
    
    /// Convert text/enriched to HTML
    private func convertToHTML(_ content: String) -> String {
        var result = content
        
        // Step 1: Handle basic formatting tags
        result = processBasicTags(result)
        
        // Step 2: Handle parameterized tags (fontfamily, color)
        result = processParameterizedTags(result)
        
        // Step 3: Handle line breaks (text/enriched uses single \n for soft breaks)
        result = processLineBreaks(result)
        
        // Step 4: Escape remaining angle brackets that aren't HTML tags
        result = escapeUnprocessedBrackets(result)
        
        // Step 5: Wrap in basic HTML structure
        return wrapInHTMLStructure(result)
    }
    
    /// Convert text/enriched to plain text by stripping all formatting
    private func convertToPlainText(_ content: String) -> String {
        var result = content
        
        // Remove all text/enriched tags using regex
        let tagPattern = "</?[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?>|</?param>.*?</param>"
        result = result.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)
        
        // Clean up extra whitespace
        result = result.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Process basic formatting tags (bold, italic, etc.)
    private func processBasicTags(_ content: String) -> String {
        var result = content
        
        for (enrichedTag, htmlTags) in tagMapping {
            let openPattern = "<\(enrichedTag)>"
            let closePattern = "</\(enrichedTag)>"
            
            result = result.replacingOccurrences(of: openPattern, with: htmlTags.open, options: .caseInsensitive)
            result = result.replacingOccurrences(of: closePattern, with: htmlTags.close, options: .caseInsensitive)
        }
        
        return result
    }
    
    /// Process parameterized tags like <fontfamily><param>Arial</param> and <color><param>red</param>
    private func processParameterizedTags(_ content: String) -> String {
        var result = content
        
        // Process fontfamily tags
        result = processParameterizedTag(result, tag: "fontfamily") { param in
            return "<span style=\"font-family: \(escapeHTMLAttribute(param))\">"
        }
        
        // Process color tags
        result = processParameterizedTag(result, tag: "color") { param in
            return "<span style=\"color: \(escapeHTMLAttribute(param))\">"
        }
        
        return result
    }
    
    /// Generic processor for parameterized tags
    private func processParameterizedTag(_ content: String, tag: String, transform: (String) -> String) -> String {
        var result = content
        
        // Pattern: <tag><param>value</param>...content...</tag>
        let pattern = "<\(tag)>\\s*<param>([^<]*)</param>(.*?)</\(tag)>"
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        
        if let regex = regex {
            let nsString = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsString.length))
            
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                if match.numberOfRanges >= 3 {
                    let paramRange = match.range(at: 1)
                    let contentRange = match.range(at: 2)
                    
                    if paramRange.location != NSNotFound && contentRange.location != NSNotFound {
                        let param = nsString.substring(with: paramRange)
                        let content = nsString.substring(with: contentRange)
                        
                        let openTag = transform(param)
                        let replacement = "\(openTag)\(content)</span>"
                        
                        result = nsString.replacingCharacters(in: match.range, with: replacement)
                    }
                }
            }
        }
        
        return result
    }
    
    /// Process line breaks according to text/enriched rules
    private func processLineBreaks(_ content: String) -> String {
        var result = content
        
        // In text/enriched, single newlines are soft breaks, double newlines are paragraphs
        // First, protect existing double newlines
        result = result.replacingOccurrences(of: "\n\n", with: "DOUBLE_NEWLINE_PLACEHOLDER")
        
        // Convert single newlines to spaces (soft breaks)
        result = result.replacingOccurrences(of: "\n", with: " ")
        
        // Restore double newlines as paragraph breaks
        result = result.replacingOccurrences(of: "DOUBLE_NEWLINE_PLACEHOLDER", with: "</p><p>")
        
        return result
    }
    
    /// Escape angle brackets that aren't part of HTML tags
    private func escapeUnprocessedBrackets(_ content: String) -> String {
        var result = content
        
        // This is a simplified approach - in production, you'd want more sophisticated parsing
        // For now, we'll assume that any remaining < or > that don't look like HTML tags should be escaped
        
        // Don't escape brackets that are part of valid HTML tags
        let htmlTagPattern = "</?[a-zA-Z][a-zA-Z0-9]*(?:\\s[^>]*)?/?>"
        let regex = try? NSRegularExpression(pattern: htmlTagPattern, options: [])
        
        if let regex = regex {
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: result.count))
            var protectedRanges = IndexSet()
            
            for match in matches {
                protectedRanges.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
            }
            
            // Escape < and > that are not in protected ranges
            var escapedResult = ""
            for (index, char) in result.enumerated() {
                if protectedRanges.contains(index) {
                    escapedResult.append(char)
                } else {
                    switch char {
                    case "<":
                        escapedResult.append("&lt;")
                    case ">":
                        escapedResult.append("&gt;")
                    default:
                        escapedResult.append(char)
                    }
                }
            }
            result = escapedResult
        }
        
        return result
    }
    
    /// Wrap content in basic HTML structure
    private func wrapInHTMLStructure(_ content: String) -> String {
        // Add paragraph tags if content doesn't already have block-level elements
        var wrappedContent = content
        
        if !content.contains("<p>") && !content.contains("<div>") && !content.contains("<blockquote>") {
            wrappedContent = "<p>\(content)</p>"
        }
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body { font-family: Arial, sans-serif; line-height: 1.4; }
                blockquote { margin: 1em 0; padding-left: 1em; border-left: 2px solid #ccc; }
            </style>
        </head>
        <body>
        \(wrappedContent)
        </body>
        </html>
        """
    }
    
    /// Escape HTML attributes to prevent XSS
    private func escapeHTMLAttribute(_ attribute: String) -> String {
        return attribute
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}