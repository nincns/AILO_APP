// EmailFormatFlowedHandler.swift - Handles format=flowed text processing
import Foundation

/// Handler for format=flowed text processing (RFC 3676)
/// This is the original simpler implementation
public class EmailFormatFlowedHandler {
    
    /// Process format=flowed text
    public static func processFormatFlowed(_ content: String, delSp: Bool = false) -> String {
        let processor = EmailFormatFlowedHandler()
        return processor.process(content, delSp: delSp)
    }
    
    /// Convert format=flowed to plain text
    public static func convertToPlainText(_ content: String, delSp: Bool = false) -> String {
        let processor = EmailFormatFlowedHandler()
        return processor.convertToPlain(content, delSp: delSp)
    }
    
    /// Convert format=flowed to HTML
    public static func convertToHTML(_ content: String, delSp: Bool = false) -> String {
        let processor = EmailFormatFlowedHandler()
        return processor.convertToHTML(content, delSp: delSp)
    }
    
    // MARK: - Private Implementation
    
    /// Process format=flowed text
    private func process(_ content: String, delSp: Bool) -> String {
        let lines = content.components(separatedBy: .newlines)
        var processedLines: [String] = []
        var currentParagraph: [String] = []
        
        for line in lines {
            let processedLine = processLine(line, delSp: delSp)
            
            if isFlowedLine(line) {
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
        
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                htmlLines.append("<br>")
            } else {
                let escapedLine = line.htmlEscaped()
                htmlLines.append("<p>\(escapedLine)</p>")
            }
        }
        
        return htmlLines.joined(separator: "\n")
    }
    
    /// Process a single line according to format=flowed rules
    private func processLine(_ line: String, delSp: Bool) -> String {
        var processedLine = line
        
        // Handle DelSp parameter
        if delSp {
            // Remove trailing space if DelSp=yes
            if processedLine.hasSuffix(" ") {
                processedLine = String(processedLine.dropLast())
            }
        }
        
        // Handle space-stuffing (remove leading space if it was added for stuffing)
        if processedLine.hasPrefix(" ") && isSpaceStuffed(line) {
            processedLine = String(processedLine.dropFirst())
        }
        
        return processedLine
    }
    
    /// Check if a line is flowed (continues to next line)
    private func isFlowedLine(_ line: String) -> Bool {
        // A line is flowed if it ends with a space (and it's not space-stuffed)
        return line.hasSuffix(" ") && !isSpaceStuffed(line)
    }
    
    /// Check if a line is space-stuffed
    private func isSpaceStuffed(_ line: String) -> Bool {
        // Space-stuffing is used for lines that naturally start with space or ">"
        // This is a simplified check - full implementation would be more complex
        return line.hasPrefix("  ") || line.hasPrefix(" >")
    }
    
    /// Join lines in a paragraph
    private func joinParagraph(_ lines: [String]) -> String {
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
