// EmailContentParser.swift - Simplified parser for already processed email content
import Foundation

/// Simplified parser class - emails are already processed and clean in database
public class EmailContentParser {
    
    // MARK: - Static Interface (maintains backward compatibility)
    
    /// Parse email content - simplified since emails are pre-processed
    public static func parseEmailContent(_ rawContent: String) -> ParsedEmailContent {
        let parser = EmailContentParser()
        return parser.parse(rawContent)
    }
    
    // MARK: - Instance Interface
    
    /// Parse email content - simplified for pre-processed content
    public func parse(_ rawContent: String) -> ParsedEmailContent {
        // Step 1: Try MIME parsing first (preferred approach)
        let mimeParser = MIMEParser()
        let mimeContent = mimeParser.parse(
            rawBodyBytes: nil,
            rawBodyString: rawContent,
            contentType: ContentDecoder.detectContentType(rawContent),
            charset: ContentDecoder.detectCharset(rawContent)
        )
        
        // Step 2: Check if MIME parsing found structured content
        if let mimeText = mimeContent.text, !mimeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // MIME parser succeeded - use its output (handles multipart automatically)
            let isHTML = mimeContent.html != nil
            let finalContent = isHTML ? (mimeContent.html ?? mimeText) : mimeText
            let encoding = ContentDecoder.detectOriginalEncoding(rawContent)
            
            // Minimal processing - content is already clean from database
            let normalizedContent = normalizeLineBreaks(finalContent)
            
            return ParsedEmailContent(
                content: normalizedContent,
                isHTML: isHTML,
                encoding: encoding
            )
        }
        
        // Step 3: Fallback to simple parsing if MIME failed
        return parseSimple(rawContent)
    }
    
    /// Simple parsing for pre-processed content
    private func parseSimple(_ rawContent: String) -> ParsedEmailContent {
        // Step 1: Detect the original encoding
        let originalEncoding = ContentDecoder.detectOriginalEncoding(rawContent)
        
        // Step 2: Decode content if needed
        let decodedContent = ContentDecoder.decodeMultipleEncodings(rawContent)
        
        // Step 3: Detect if content is HTML or plain text
        let isHTML = ContentAnalyzer.detectHTMLContent(decodedContent)
        
        // Step 4: Minimal cleanup - just normalize line breaks
        let normalizedContent = normalizeLineBreaks(decodedContent)
        
        return ParsedEmailContent(
            content: normalizedContent,
            isHTML: isHTML,
            encoding: originalEncoding
        )
    }
    
    // MARK: - Advanced Parsing Options
    
    /// Parse with custom options - simplified for pre-processed content
    public func parseWithOptions(_ rawContent: String, options: ParsingOptions) -> ParsedEmailContent {
        var content = rawContent
        
        // Apply custom decoding if specified
        if options.useAdvancedDecoding {
            content = ContentDecoder.decodeMultipleEncodings(content)
        } else {
            content = ContentDecoder.decodeQuotedPrintable(content)
        }
        
        // Minimal processing since content is already clean
        content = normalizeLineBreaks(content)
        
        let isHTML = ContentAnalyzer.detectHTMLContent(content)
        let encoding = ContentDecoder.detectOriginalEncoding(rawContent)
        
        return ParsedEmailContent(
            content: content,
            isHTML: isHTML,
            encoding: encoding
        )
    }
    
    // MARK: - Helper Methods
    
    /// Normalize line breaks (minimal processing)
    private func normalizeLineBreaks(_ content: String) -> String {
        // Normalize different line break formats
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
    
    /// Extract boundary from Content-Type header
    private func extractBoundary(from contentType: String) -> String? {
        let lowercased = contentType.lowercased()
        
        if let range = lowercased.range(of: "boundary=") {
            let boundaryPart = String(contentType[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Handle quoted boundaries
            if boundaryPart.hasPrefix("\"") && boundaryPart.count > 1 {
                let withoutFirstQuote = String(boundaryPart.dropFirst())
                if let endQuote = withoutFirstQuote.firstIndex(of: "\"") {
                    return String(withoutFirstQuote[..<endQuote])
                }
            }
            
            // Handle unquoted boundaries
            let boundary = boundaryPart.components(separatedBy: CharacterSet(charactersIn: " \t\r\n;\"'"))[0]
            return boundary.isEmpty ? nil : boundary
        }
        
        return nil
    }
    
    /// Extract Content-Transfer-Encoding from headers  
    private func extractTransferEncoding(from content: String) -> String? {
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
        
        return nil
    }
    
    /// Extract and decode email headers (simplified approach)
    private func extractEmailHeaders(from content: String) -> (subject: String?, from: String?, to: String?) {
        let lines = content.components(separatedBy: .newlines).prefix(50)
        
        var subject: String?
        var from: String?
        var to: String?
        var currentHeader = ""
        var currentValue = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.isEmpty {
                break // End of headers
            }
            
            // Continuation line
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + trimmed
                continue
            }
            
            // Save previous header
            if !currentHeader.isEmpty && !currentValue.isEmpty {
                switch currentHeader.lowercased() {
                case "subject":
                    subject = decodeHeaderValue(currentValue)
                case "from":
                    from = decodeHeaderValue(currentValue)
                case "to":
                    to = decodeHeaderValue(currentValue)
                default:
                    break
                }
            }
            
            // Parse new header
            if let colonIndex = trimmed.firstIndex(of: ":") {
                currentHeader = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                currentValue = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                currentHeader = ""
                currentValue = ""
            }
        }
        
        // Handle final header
        if !currentHeader.isEmpty && !currentValue.isEmpty {
            switch currentHeader.lowercased() {
            case "subject":
                subject = decodeHeaderValue(currentValue)
            case "from":
                from = decodeHeaderValue(currentValue)
            case "to":
                to = decodeHeaderValue(currentValue)
            default:
                break
            }
        }
        
        return (subject: subject, from: from, to: to)
    }
    
    /// Simple header value decoding (can be enhanced with RFC2047 later)
    private func decodeHeaderValue(_ value: String) -> String {
        // For now, just return the value as-is
        // This can be enhanced with proper RFC2047 decoding later
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Configuration options for email parsing
public struct ParsingOptions {
    public let useAdvancedDecoding: Bool
    public let preferRenderedContent: Bool
    public let aggressiveCleaning: Bool
    
    public init(useAdvancedDecoding: Bool = true, 
                preferRenderedContent: Bool = true, 
                aggressiveCleaning: Bool = false) {
        self.useAdvancedDecoding = useAdvancedDecoding
        self.preferRenderedContent = preferRenderedContent
        self.aggressiveCleaning = aggressiveCleaning
    }
    
    /// Default parsing options
    public static let `default` = ParsingOptions()
    
    /// Conservative parsing (minimal changes)
    public static let conservative = ParsingOptions(
        useAdvancedDecoding: false,
        preferRenderedContent: false,
        aggressiveCleaning: false
    )
    
    /// Aggressive parsing (maximum cleaning)
    public static let aggressive = ParsingOptions(
        useAdvancedDecoding: true,
        preferRenderedContent: true,
        aggressiveCleaning: true
    )
}

/// Represents parsed email content with metadata (enhanced with multipart support)
public struct ParsedEmailContent {
    
    /// Multipart types for email content
    public enum MultipartType: String, CaseIterable {
        case alternative = "multipart/alternative"  // Different formats of same content
        case mixed = "multipart/mixed"              // Text + attachments
        case related = "multipart/related"          // HTML with embedded images
        case signed = "multipart/signed"            // Digitally signed emails
        case encrypted = "multipart/encrypted"      // Encrypted emails
        case report = "multipart/report"            // Delivery/read receipts
        case digest = "multipart/digest"            // Multiple messages
        case parallel = "multipart/parallel"       // Parts to be viewed simultaneously
        case unknown = "multipart/unknown"          // Unknown multipart type
        
        /// Create from Content-Type string
        public static func from(_ contentType: String?) -> MultipartType {
            guard let ct = contentType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .unknown
            }
            
            for type in MultipartType.allCases {
                if ct.hasPrefix(type.rawValue) {
                    return type
                }
            }
            return .unknown
        }
    }
    
    public let content: String
    public let isHTML: Bool
    public let encoding: String
    public let subject: String?
    public let from: String?
    public let to: String?
    public let multipartType: MultipartType?
    public let hasAttachments: Bool
    public let hasInlineImages: Bool
    public let attachmentCount: Int
    
    public init(content: String, isHTML: Bool, encoding: String, subject: String? = nil, from: String? = nil, to: String? = nil, multipartType: MultipartType? = nil, hasAttachments: Bool = false, hasInlineImages: Bool = false, attachmentCount: Int = 0) {
        self.content = content
        self.isHTML = isHTML  
        self.encoding = encoding
        self.subject = subject
        self.from = from
        self.to = to
        self.multipartType = multipartType
        self.hasAttachments = hasAttachments
        self.hasInlineImages = hasInlineImages
        self.attachmentCount = attachmentCount
    }
}