// EmailMultipartHandler.swift - Handles different types of multipart email content
import Foundation

/// Handles different types of multipart content with type-specific parsing logic
public class EmailMultipartHandler {
    
    /// Supported multipart types with specific handling logic
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
        
        /// Get priority for multipart/alternative selection
        public var priority: Int {
            switch self {
            case .alternative: return 3  // Highest priority for alternative content
            case .mixed: return 2        // Medium priority for mixed content
            case .related: return 2      // Medium priority for related content
            case .signed: return 1       // Lower priority, needs special handling
            case .encrypted: return 1    // Lower priority, needs special handling
            default: return 0            // Lowest priority
            }
        }
    }
    
    /// Handle multipart content based on its type
    public static func handleMultipartContent(
        _ parts: [MultipartPart],
        type: MultipartType,
        preferHTML: Bool = true
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        switch type {
        case .alternative:
            return handleMultipartAlternative(parts, preferHTML: preferHTML)
        case .mixed:
            return handleMultipartMixed(parts, preferHTML: preferHTML)
        case .related:
            return handleMultipartRelated(parts, preferHTML: preferHTML)
        case .signed:
            return handleMultipartSigned(parts, preferHTML: preferHTML)
        case .encrypted:
            return handleMultipartEncrypted(parts, preferHTML: preferHTML)
        case .report:
            return handleMultipartReport(parts, preferHTML: preferHTML)
        case .digest:
            return handleMultipartDigest(parts, preferHTML: preferHTML)
        case .parallel:
            return handleMultipartParallel(parts, preferHTML: preferHTML)
        case .unknown:
            return handleMultipartGeneric(parts, preferHTML: preferHTML)
        }
    }
    
    // MARK: - Type-Specific Handlers
    
    /// Handle multipart/alternative (choose best format)
    private static func handleMultipartAlternative(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        var textPart: String?
        var htmlPart: String?
        var attachments: [EmailAttachment] = []
        
        // Sort parts by preference
        let sortedParts = parts.sorted { (part1, part2) -> Bool in
            let priority1 = getContentTypePriority(part1.contentType, preferHTML: preferHTML)
            let priority2 = getContentTypePriority(part2.contentType, preferHTML: preferHTML)
            return priority1 > priority2
        }
        
        for part in sortedParts {
            let contentType = part.contentType.lowercased()
            
            if contentType.hasPrefix("text/plain") && textPart == nil {
                textPart = part.content
            } else if contentType.hasPrefix("text/html") && htmlPart == nil {
                htmlPart = part.content
            } else if contentType.hasPrefix("text/enriched") {
                // Convert text/enriched to HTML
                let enrichedHTML = TextEnrichedDecoder.decodeToHTML(part.content)
                if htmlPart == nil { htmlPart = enrichedHTML }
                if textPart == nil { textPart = TextEnrichedDecoder.decodeToPlainText(part.content) }
            } else {
                // Convert to attachment
                attachments.append(EmailAttachment(from: part))
            }
        }
        
        return (text: textPart, html: htmlPart, attachments: attachments)
    }
    
    /// Handle multipart/mixed (text + attachments)
    private static func handleMultipartMixed(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        var textPart: String?
        var htmlPart: String?
        var attachments: [EmailAttachment] = []
        
        for part in parts {
            let contentType = part.contentType.lowercased()
            
            if contentType.hasPrefix("text/plain") {
                textPart = combineTextContent(textPart, part.content)
            } else if contentType.hasPrefix("text/html") {
                htmlPart = combineHTMLContent(htmlPart, part.content)
            } else if contentType.hasPrefix("text/enriched") {
                let enrichedHTML = TextEnrichedDecoder.decodeToHTML(part.content)
                htmlPart = combineHTMLContent(htmlPart, enrichedHTML)
                let enrichedText = TextEnrichedDecoder.decodeToPlainText(part.content)
                textPart = combineTextContent(textPart, enrichedText)
            } else if contentType.hasPrefix("multipart/") {
                // Nested multipart - handle recursively
                let nestedType = MultipartType.from(part.contentType)
                let nested = handleMultipartContent(part.subparts ?? [], type: nestedType, preferHTML: preferHTML)
                
                if let nestedText = nested.text {
                    textPart = combineTextContent(textPart, nestedText)
                }
                if let nestedHTML = nested.html {
                    htmlPart = combineHTMLContent(htmlPart, nestedHTML)
                }
                attachments.append(contentsOf: nested.attachments)
            } else {
                // Attachment
                attachments.append(EmailAttachment(from: part))
            }
        }
        
        return (text: textPart, html: htmlPart, attachments: attachments)
    }
    
    /// Handle multipart/related (HTML with embedded images)
    private static func handleMultipartRelated(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        var textPart: String?
        var htmlPart: String?
        var attachments: [EmailAttachment] = []
        var inlineAttachments: [String: EmailAttachment] = [:]
        
        // First pass: collect inline attachments
        for part in parts {
            if let contentId = part.contentId, !part.contentType.hasPrefix("text/") {
                let attachment = EmailAttachment(from: part)
                inlineAttachments[contentId] = attachment
            }
        }
        
        // Second pass: process text parts and resolve inline references
        for part in parts {
            let contentType = part.contentType.lowercased()
            
            if contentType.hasPrefix("text/plain") {
                textPart = combineTextContent(textPart, part.content)
            } else if contentType.hasPrefix("text/html") {
                var htmlContent = part.content
                // Resolve cid: references
                htmlContent = resolveInlineReferences(htmlContent, inlineAttachments: inlineAttachments)
                htmlPart = combineHTMLContent(htmlPart, htmlContent)
            } else if contentType.hasPrefix("text/enriched") {
                let enrichedHTML = TextEnrichedDecoder.decodeToHTML(part.content)
                let resolvedHTML = resolveInlineReferences(enrichedHTML, inlineAttachments: inlineAttachments)
                htmlPart = combineHTMLContent(htmlPart, resolvedHTML)
                textPart = combineTextContent(textPart, TextEnrichedDecoder.decodeToPlainText(part.content))
            } else if part.contentId == nil {
                // Non-inline attachment
                attachments.append(EmailAttachment(from: part))
            }
        }
        
        // Add inline attachments that weren't embedded
        attachments.append(contentsOf: inlineAttachments.values)
        
        return (text: textPart, html: htmlPart, attachments: attachments)
    }
    
    /// Handle multipart/signed (digitally signed)
    private static func handleMultipartSigned(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        // For signed messages, typically the first part is the content,
        // and the second part is the signature
        if parts.count >= 2 {
            let contentPart = parts[0]
            let signaturePart = parts[1]
            
            // Process the main content part
            var result = handleMultipartGeneric([contentPart], preferHTML: preferHTML)
            
            // Add signature as attachment
            result.attachments.append(EmailAttachment(from: signaturePart))
            
            return result
        }
        
        return handleMultipartGeneric(parts, preferHTML: preferHTML)
    }
    
    /// Handle multipart/encrypted (encrypted content)
    private static func handleMultipartEncrypted(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        // For encrypted messages, we typically can't decrypt the content
        // Return parts as attachments
        let attachments = parts.map { EmailAttachment(from: $0) }
        return (text: "Encrypted content", html: "<p>Encrypted content</p>", attachments: attachments)
    }
    
    /// Handle multipart/report (delivery/read receipts)
    private static func handleMultipartReport(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        var textPart: String?
        var htmlPart: String?
        var attachments: [EmailAttachment] = []
        
        for part in parts {
            if part.contentType.hasPrefix("text/plain") {
                textPart = combineTextContent(textPart, part.content)
            } else if part.contentType.hasPrefix("text/html") {
                htmlPart = combineHTMLContent(htmlPart, part.content)
            } else {
                attachments.append(EmailAttachment(from: part))
            }
        }
        
        return (text: textPart, html: htmlPart, attachments: attachments)
    }
    
    /// Handle multipart/digest (multiple messages)
    private static func handleMultipartDigest(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        // Digest parts are typically message/rfc822
        var combinedText = ""
        var combinedHTML = ""
        
        for (index, part) in parts.enumerated() {
            combinedText += "--- Message \(index + 1) ---\n"
            combinedText += part.content + "\n\n"
            
            combinedHTML += "<hr><h3>Message \(index + 1)</h3>"
            combinedHTML += "<pre>" + part.content.htmlEscaped() + "</pre><br>"
        }
        
        return (text: combinedText.isEmpty ? nil : combinedText,
                html: combinedHTML.isEmpty ? nil : combinedHTML,
                attachments: [])
    }
    
    /// Handle multipart/parallel (parts viewed simultaneously)
    private static func handleMultipartParallel(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        // For parallel, combine all text parts
        return handleMultipartMixed(parts, preferHTML: preferHTML)
    }
    
    /// Generic multipart handler
    private static func handleMultipartGeneric(
        _ parts: [MultipartPart],
        preferHTML: Bool
    ) -> (text: String?, html: String?, attachments: [EmailAttachment]) {
        
        return handleMultipartMixed(parts, preferHTML: preferHTML)
    }
    
    // MARK: - Helper Methods
    
    /// Get priority for content type
    private static func getContentTypePriority(_ contentType: String, preferHTML: Bool) -> Int {
        let ct = contentType.lowercased()
        
        if preferHTML {
            if ct.hasPrefix("text/html") { return 3 }
            if ct.hasPrefix("text/enriched") { return 2 }
            if ct.hasPrefix("text/plain") { return 1 }
        } else {
            if ct.hasPrefix("text/plain") { return 3 }
            if ct.hasPrefix("text/enriched") { return 2 }
            if ct.hasPrefix("text/html") { return 1 }
        }
        
        return 0
    }
    
    /// Combine text content
    private static func combineTextContent(_ existing: String?, _ new: String) -> String {
        guard let existing = existing, !existing.isEmpty else { return new }
        return existing + "\n\n" + new
    }
    
    /// Combine HTML content
    private static func combineHTMLContent(_ existing: String?, _ new: String) -> String {
        guard let existing = existing, !existing.isEmpty else { return new }
        return existing + "<br><br>" + new
    }
    
    /// Resolve inline references (cid: URLs)
    private static func resolveInlineReferences(_ html: String, inlineAttachments: [String: EmailAttachment]) -> String {
        var resolvedHTML = html
        
        for (contentId, attachment) in inlineAttachments {
            let cidPattern = "cid:\(contentId)"
            // This is a simplified approach - in production you'd want to embed the actual data
            let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            resolvedHTML = resolvedHTML.replacingOccurrences(of: cidPattern, with: dataURL)
        }
        
        return resolvedHTML
    }
}

// MARK: - Supporting Types

/// Represents a multipart part
public struct MultipartPart {
    public let contentType: String
    public let content: String
    public let contentId: String?
    public let filename: String?
    public let isInline: Bool
    public let subparts: [MultipartPart]?
    
    public init(contentType: String, content: String, contentId: String? = nil, filename: String? = nil, isInline: Bool = false, subparts: [MultipartPart]? = nil) {
        self.contentType = contentType
        self.content = content
        self.contentId = contentId
        self.filename = filename
        self.isInline = isInline
        self.subparts = subparts
    }
}

/// Represents an email attachment
public struct EmailAttachment {
    public let filename: String
    public let mimeType: String
    public let data: Data
    public let contentId: String?
    public let isInline: Bool
    
    public init(filename: String, mimeType: String, data: Data, contentId: String? = nil, isInline: Bool = false) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
    }
    
    /// Create from MultipartPart
    public init(from part: MultipartPart) {
        self.filename = part.filename ?? "attachment"
        self.mimeType = part.contentType
        self.data = Data(part.content.utf8)  // Simplified - should handle encoding properly
        self.contentId = part.contentId
        self.isInline = part.isInline
    }
}

// MARK: - String Extensions
// HTML escaping extension moved to String+HTMLEscaping.swift