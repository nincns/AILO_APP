// ContentDecoder.swift - Handles encoding detection and content decoding
import Foundation

/// Handles encoding detection and content decoding operations
public class ContentDecoder {
    
    /// Universal quoted-printable decoder that handles both UTF-8 and Latin-1
    public static func decodeQuotedPrintable(_ content: String) -> String {
        // Use the new QuotedPrintableDecoder with charset detection
        let charset = detectCharset(content)
        return QuotedPrintableDecoder.decode(content, charset: charset)
    }
    
    /// Detect and decode multiple encoding layers (enhanced with TransferEncodingDecoder and TextEnriched support)
    public static func decodeMultipleEncodings(_ content: String) -> String {
        // First try full MIME parsing for multipart handling
        let mimeParser = MIMEParser()
        let mimeContent = mimeParser.parse(
            rawBodyBytes: nil,
            rawBodyString: content,
            contentType: detectContentType(content),
            charset: detectCharset(content)
        )
        
        // If MIME parser found structured content, use it (handles multipart automatically)
        if let mimeText = mimeContent.text, !mimeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let finalContent = mimeContent.html ?? mimeText
            
            // Check if the content is text/enriched and convert to HTML
            if TextEnrichedDecoder.isTextEnriched(finalContent) {
                return TextEnrichedDecoder.decodeToHTML(finalContent)
            }
            
            return finalContent
        }
        
        // Enhanced: Use TransferEncodingDecoder for comprehensive decoding
        let detectedEncoding = detectTransferEncoding(content)
        let charset = detectCharset(content)
        
        let decoded = TransferEncodingDecoder.decode(content, encoding: detectedEncoding, charset: charset)
        
        // Check if the decoded content is text/enriched
        if TextEnrichedDecoder.isTextEnriched(decoded) {
            return TextEnrichedDecoder.decodeToHTML(decoded)
        }
        
        // If decoding made significant changes, return the result
        if decoded != content {
            return decoded
        }
        
        // Last fallback: try base64 decoding if pattern matches
        if content.range(of: "^[A-Za-z0-9+/]*={0,2}$", options: .regularExpression) != nil &&
           content.count > 20 && content.count % 4 == 0 {
            let base64Decoded = decodeBase64(content)
            if !base64Decoded.isEmpty && base64Decoded != content {
                // Check if base64 decoded content is text/enriched
                if TextEnrichedDecoder.isTextEnriched(base64Decoded) {
                    return TextEnrichedDecoder.decodeToHTML(base64Decoded)
                }
                return base64Decoded
            }
        }
        
        // Final check for text/enriched in original content
        if TextEnrichedDecoder.isTextEnriched(content) {
            return TextEnrichedDecoder.decodeToHTML(content)
        }
        
        return content
    }
    
    /// Decode Text/Enriched content to HTML or plain text
    public static func decodeTextEnriched(_ content: String, toHTML: Bool = true) -> String {
        if toHTML {
            return TextEnrichedDecoder.decodeToHTML(content)
        } else {
            return TextEnrichedDecoder.decodeToPlainText(content)
        }
    }
    
    /// Check if content is in text/enriched format
    public static func isTextEnriched(_ content: String) -> Bool {
        return TextEnrichedDecoder.isTextEnriched(content)
    }
    
    /// Detect the original encoding from raw content
    public static func detectOriginalEncoding(_ content: String) -> String {
        if content.contains("charset=utf-8") {
            return "utf-8"
        } else if content.contains("charset=iso-8859-1") {
            return "iso-8859-1"
        } else if content.contains("quoted-printable") {
            return "quoted-printable"
        } else if content.contains("text/enriched") || TextEnrichedDecoder.isTextEnriched(content) {
            return "text/enriched"
        } else {
            return "unknown"
        }
    }
    
    /// Decode Base64 encoded content
    public static func decodeBase64(_ content: String) -> String {
        guard let data = Data(base64Encoded: content),
              let decoded = String(data: data, encoding: .utf8) else {
            return content // Return original if decoding fails
        }
        return decoded
    }
    
    /// Convert content from one charset to another
    public static func convertCharset(_ content: String, from sourceEncoding: String, to targetEncoding: String = "utf-8") -> String {
        // For now, return content as-is since we're working with Swift Strings
        // This could be extended later for more sophisticated charset conversion
        return content
    }
    
    /// Normalize charset identifier (e.g., "UTF-8" -> "utf-8")
    public static func normalizeCharset(_ charset: String) -> String {
        let normalized = charset.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        
        // Common normalizations
        switch normalized {
        case "utf8": return "utf-8"
        case "iso88591", "latin1": return "iso-8859-1"
        case "ascii": return "us-ascii"
        default: return normalized
        }
    }
    
    /// Detect transfer encoding from content headers
    public static func detectTransferEncoding(_ content: String) -> String? {
        let lines = content.components(separatedBy: .newlines).prefix(30)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            
            if lowercased.hasPrefix("content-transfer-encoding:") {
                let value = String(trimmed.dropFirst("content-transfer-encoding:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        
        // Try to detect based on content patterns
        if content.contains("=") && content.range(of: "=[0-9A-F]{2}", options: .regularExpression) != nil {
            return "quoted-printable"
        }
        
        // Check for Base64 pattern
        if content.range(of: "^[A-Za-z0-9+/]*={0,2}$", options: .regularExpression) != nil &&
           content.count > 20 && content.count % 4 == 0 {
            return "base64"
        }
        
        return nil // 7bit or 8bit (no encoding)
    }
    
    /// Detect content type from raw content headers
    public static func detectContentType(_ content: String) -> String? {
        let lines = content.components(separatedBy: .newlines).prefix(20)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("content-type:") {
                return String(trimmed.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
    
    /// Detect charset from raw content headers (simple inline detection)
    public static func detectCharset(_ content: String) -> String? {
        // Simple charset detection from Content-Type headers
        let lines = content.components(separatedBy: .newlines).prefix(20)
        
        for line in lines {
            let lowercased = line.lowercased()
            if lowercased.contains("content-type:") && lowercased.contains("charset=") {
                // Extract charset value
                if let charsetRange = lowercased.range(of: "charset=") {
                    let afterCharset = String(line[charsetRange.upperBound...])
                    let charset = afterCharset.components(separatedBy: CharacterSet(charactersIn: "; \t\r\n\"'")).first ?? ""
                    let cleanCharset = charset.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !cleanCharset.isEmpty && cleanCharset.lowercased() != "utf-8" {
                        return cleanCharset
                    }
                }
            }
        }
        
        return nil // Default to UTF-8
    }
}