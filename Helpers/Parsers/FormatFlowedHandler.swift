// FormatFlowedHandler.swift - Enhanced format=flowed text processing with better RFC 3676 support
import Foundation

/// Enhanced handler for format=flowed text processing (RFC 3676)
public class FormatFlowedHandler {
    
    /// Process format=flowed text according to RFC 3676
    public static func processFlowedText(_ content: String, delSp: Bool = false) -> String {
        let processor = FormatFlowedHandler()
        return processor.process(content, delSp: delSp)
    }
    
    /// Check if Content-Type indicates format=flowed
    public static func isFormatFlowed(_ contentType: String?) -> (isFlowed: Bool, delSp: Bool) {
        guard let contentType = contentType else {
            return (false, false)
        }
        
        let lowercased = contentType.lowercased()
        let isFlowed = lowercased.contains("format=flowed")
        let delSp = lowercased.contains("delsp=yes")
        
        return (isFlowed, delSp)
    }
    
    /// Convert format=flowed to plain text
    public static func convertToPlainText(_ content: String, delSp: Bool = false) -> String {
        let processor = FormatFlowedHandler()
        return processor.convertToPlain(content, delSp: delSp)
    }
    
    /// Convert format=flowed to HTML
    public static func convertToHTML(_ content: String, delSp: Bool = false) -> String {
        let processor = FormatFlowedHandler()
        return processor.convertToHTML(content, delSp: delSp)
    }
    
    // MARK: - Private Implementation
    
    /// Process format=flowed text
    private func process(_ content: String, delSp: Bool) -> String {
        let lines = content.components(separatedBy: .newlines)
        var processedLines: [String] = []
        var currentParagraph: [String] = []
        var quoteDepth = 0
        
        for line in lines {
            let (processedLine, lineQuoteDepth) = processLine(line, delSp: delSp)
            
            // Handle quote depth changes
            if lineQuoteDepth != quoteDepth {
                // Quote depth changed - finalize current paragraph
                if !currentParagraph.isEmpty {
                    processedLines.append(joinParagraph(currentParagraph))
                    currentParagraph = []
                }
                quoteDepth = lineQuoteDepth
            }
            
            if isFlowedLine(line, quoteDepth: lineQuoteDepth) {
                // This line continues to the next
                currentParagraph.append(processedLine)
            } else {
                // This line ends a paragraph
                currentParagraph.append(processedLine)
                processedLines.append(joinParagraph(currentParagraph))
                currentParagraph = []
            }
        }
        
        // Handle any remaining paragraph
        if !currentParagraph.isEmpty {
            processedLines.append(joinParagraph(currentParagraph))
        }
        
        return processedLines.joined(separator: "\n")
    }
    
    /// Convert to plain text format
    private func convertToPlain(_ content: String, delSp: Bool) -> String {
        return process(content, delSp: delSp)
    }
    
    /// Convert to HTML format
    private func convertToHTML(_ content: String, delSp: Bool) -> String {
        let plainText = process(content, delSp: delSp)
        let lines = plainText.components(separatedBy: .newlines)
        var htmlLines: [String] = []
        var inQuote = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmedLine.isEmpty {
                if inQuote {
                    htmlLines.append("</blockquote>")
                    inQuote = false
                }
                htmlLines.append("<br>")
            } else {
                let (quotedLine, quoteDepth) = extractQuoteDepth(line)
                let escapedLine = htmlEscape(quotedLine)
                
                if quoteDepth > 0 {
                    if !inQuote {
                        htmlLines.append("<blockquote>")
                        inQuote = true
                    }
                    htmlLines.append("<p>\(escapedLine)</p>")
                } else {
                    if inQuote {
                        htmlLines.append("</blockquote>")
                        inQuote = false
                    }
                    htmlLines.append("<p>\(escapedLine)</p>")
                }
            }
        }
        
        if inQuote {
            htmlLines.append("</blockquote>")
        }
        
        return htmlLines.joined(separator: "\n")
    }
    
    /// Process a single line according to format=flowed rules
    private func processLine(_ line: String, delSp: Bool) -> (processedLine: String, quoteDepth: Int) {
        var processedLine = line
        let (unquotedLine, quoteDepth) = extractQuoteDepth(line)
        
        // Handle DelSp parameter
        if delSp {
            // Remove trailing space if DelSp=yes
            if unquotedLine.hasSuffix(" ") {
                let withoutTrailingSpace = String(unquotedLine.dropLast())
                processedLine = reconstructWithQuotes(withoutTrailingSpace, quoteDepth: quoteDepth)
            }
        }
        
        // Handle space-stuffing (remove leading space if it was added for stuffing)
        if unquotedLine.hasPrefix(" ") && isSpaceStuffed(unquotedLine) {
            let withoutStuffing = String(unquotedLine.dropFirst())
            processedLine = reconstructWithQuotes(withoutStuffing, quoteDepth: quoteDepth)
        }
        
        return (processedLine, quoteDepth)
    }
    
    /// Extract quote depth and return unquoted line
    private func extractQuoteDepth(_ line: String) -> (unquotedLine: String, quoteDepth: Int) {
        var depth = 0
        var index = line.startIndex
        
        // Count leading ">" characters
        while index < line.endIndex {
            let char = line[index]
            if char == ">" {
                depth += 1
                index = line.index(after: index)
                
                // Skip optional space after ">"
                if index < line.endIndex && line[index] == " " {
                    index = line.index(after: index)
                }
            } else {
                break
            }
        }
        
        let unquotedLine = String(line[index...])
        return (unquotedLine, depth)
    }
    
    /// Reconstruct line with quote prefixes
    private func reconstructWithQuotes(_ content: String, quoteDepth: Int) -> String {
        guard quoteDepth > 0 else { return content }
        
        let quotePrefix = String(repeating: "> ", count: quoteDepth)
        return quotePrefix + content
    }
    
    /// Check if a line is flowed (continues to next line)
    private func isFlowedLine(_ line: String, quoteDepth: Int) -> Bool {
        let (unquotedLine, _) = extractQuoteDepth(line)
        
        // A line is flowed if it ends with a space (and it's not space-stuffed)
        return unquotedLine.hasSuffix(" ") && !isSpaceStuffed(unquotedLine)
    }
    
    /// Check if a line is space-stuffed
    private func isSpaceStuffed(_ unquotedLine: String) -> Bool {
        // Space-stuffing is used for lines that naturally start with space, ">", or "From "
        // RFC 3676 section 4.4
        if unquotedLine.hasPrefix(" ") {
            let afterSpace = String(unquotedLine.dropFirst())
            return afterSpace.hasPrefix(" ") || // Double space
                   afterSpace.hasPrefix(">") ||  // Space before quote
                   afterSpace.lowercased().hasPrefix("from ")  // Space before "From "
        }
        
        return false
    }
    
    /// Join lines in a paragraph
    private func joinParagraph(_ lines: [String]) -> String {
        if lines.isEmpty { return "" }
        if lines.count == 1 { return lines[0] }
        
        // Extract quote depth from first line
        let (_, quoteDepth) = extractQuoteDepth(lines[0])
        
        // Join unquoted portions
        let unquotedLines = lines.map { line in
            let (unquoted, _) = extractQuoteDepth(line)
            return unquoted
        }
        
        let joined = unquotedLines.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Reconstruct with quotes
        return reconstructWithQuotes(joined, quoteDepth: quoteDepth)
    }
    
    /// HTML escape helper function
    private func htmlEscape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }
}