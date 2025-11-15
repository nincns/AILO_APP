// SecureMailPartHandler.swift
// Sichere Verarbeitung von Email-Parts mit XSS-Schutz und Sanitization
// Phase 7: Secure mail part handling with comprehensive sanitization

import Foundation
import WebKit

// MARK: - Secure Mail Part Handler

class SecureMailPartHandler {
    
    private let securityPolicy: SecurityPolicy
    private let allowedDomains: Set<String>
    private let maxProcessingSize: Int
    
    // MARK: - Security Policy
    
    struct SecurityPolicy {
        let allowExternalImages: Bool
        let allowExternalStylesheets: Bool
        let allowInlineStyles: Bool
        let allowScripts: Bool
        let allowIframes: Bool
        let allowForms: Bool
        let proxifyExternalContent: Bool
        let enforceCSP: Bool
        
        static let strict = SecurityPolicy(
            allowExternalImages: false,
            allowExternalStylesheets: false,
            allowInlineStyles: false,
            allowScripts: false,
            allowIframes: false,
            allowForms: false,
            proxifyExternalContent: true,
            enforceCSP: true
        )
        
        static let moderate = SecurityPolicy(
            allowExternalImages: true,
            allowExternalStylesheets: false,
            allowInlineStyles: true,
            allowScripts: false,
            allowIframes: false,
            allowForms: false,
            proxifyExternalContent: true,
            enforceCSP: true
        )
        
        static let relaxed = SecurityPolicy(
            allowExternalImages: true,
            allowExternalStylesheets: true,
            allowInlineStyles: true,
            allowScripts: false,
            allowIframes: true,
            allowForms: true,
            proxifyExternalContent: false,
            enforceCSP: false
        )
    }
    
    // MARK: - Initialization
    
    init(securityPolicy: SecurityPolicy = .moderate,
         allowedDomains: Set<String> = [],
         maxProcessingSize: Int = 10 * 1024 * 1024) {
        self.securityPolicy = securityPolicy
        self.allowedDomains = allowedDomains
        self.maxProcessingSize = maxProcessingSize
    }
    
    // MARK: - Process Mail Part
    
    func processPart(_ part: MimePartEntity, content: Data) throws -> ProcessedPart {
        // Check size limit
        guard content.count <= maxProcessingSize else {
            throw ProcessingError.contentTooLarge
        }
        
        let mediaType = part.mediaType.lowercased()
        
        switch mediaType {
        case let type where type.contains("text/html"):
            return try processHtmlPart(part, content: content)
            
        case let type where type.contains("text/plain"):
            return try processTextPart(part, content: content)
            
        case let type where type.contains("text/enriched"):
            return try processEnrichedTextPart(part, content: content)
            
        case let type where type.contains("image/"):
            return try processImagePart(part, content: content)
            
        default:
            // Other types are handled as attachments
            return ProcessedPart(
                partId: part.partId,
                content: content,
                processedContent: nil,
                mediaType: part.mediaType,
                isSafe: true,
                warnings: []
            )
        }
    }
    
    // MARK: - HTML Processing
    
    private func processHtmlPart(_ part: MimePartEntity, content: Data) throws -> ProcessedPart {
        guard let html = String(data: content, encoding: .utf8) ??
                        String(data: content, encoding: .isoLatin1) else {
            throw ProcessingError.invalidEncoding
        }
        
        var warnings: [String] = []
        
        // Parse HTML
        let sanitizer = HTMLSanitizer(policy: securityPolicy)
        var sanitized = html
        
        // Remove dangerous elements
        sanitized = sanitizer.removeScripts(sanitized)
        sanitized = sanitizer.removeEventHandlers(sanitized)
        
        if !securityPolicy.allowForms {
            sanitized = sanitizer.removeForms(sanitized)
        }
        
        if !securityPolicy.allowIframes {
            sanitized = sanitizer.removeIframes(sanitized)
        }
        
        // Process styles
        if !securityPolicy.allowInlineStyles {
            sanitized = sanitizer.removeInlineStyles(sanitized)
            warnings.append("Inline styles removed")
        }
        
        if !securityPolicy.allowExternalStylesheets {
            sanitized = sanitizer.removeExternalStylesheets(sanitized)
            warnings.append("External stylesheets removed")
        }
        
        // Process images
        if !securityPolicy.allowExternalImages {
            let (processed, imageWarning) = sanitizer.blockExternalImages(sanitized)
            sanitized = processed
            if imageWarning {
                warnings.append("External images blocked")
            }
        } else if securityPolicy.proxifyExternalContent {
            sanitized = sanitizer.proxifyImages(sanitized)
        }
        
        // Process links
        sanitized = sanitizer.sanitizeLinks(sanitized, allowedDomains: allowedDomains)
        
        // Add CSP meta tag if needed
        if securityPolicy.enforceCSP {
            sanitized = addCSPMetaTag(to: sanitized)
        }
        
        // Validate final HTML
        let validation = validateHTML(sanitized)
        if !validation.isValid {
            warnings.append(contentsOf: validation.errors)
        }
        
        return ProcessedPart(
            partId: part.partId,
            content: content,
            processedContent: sanitized.data(using: .utf8),
            mediaType: "text/html",
            isSafe: validation.isValid,
            warnings: warnings
        )
    }
    
    // MARK: - Plain Text Processing
    
    private func processTextPart(_ part: MimePartEntity, content: Data) throws -> ProcessedPart {
        guard let text = String(data: content, encoding: .utf8) ??
                        String(data: content, encoding: .isoLatin1) else {
            throw ProcessingError.invalidEncoding
        }
        
        // Convert to safe HTML for display
        let escaped = escapeHtml(text)
        let html = "<pre>\(escaped)</pre>"
        
        // Auto-link URLs and emails
        let linked = autoLinkText(html)
        
        return ProcessedPart(
            partId: part.partId,
            content: content,
            processedContent: linked.data(using: .utf8),
            mediaType: "text/html", // Converted to HTML for display
            isSafe: true,
            warnings: []
        )
    }
    
    // MARK: - Enriched Text Processing
    
    private func processEnrichedTextPart(_ part: MimePartEntity, content: Data) throws -> ProcessedPart {
        guard let text = String(data: content, encoding: .utf8) else {
            throw ProcessingError.invalidEncoding
        }
        
        // Convert enriched text to HTML
        let html = convertEnrichedToHtml(text)
        
        // Process as HTML
        return try processHtmlPart(part, content: html.data(using: .utf8)!)
    }
    
    // MARK: - Image Processing
    
    private func processImagePart(_ part: MimePartEntity, content: Data) throws -> ProcessedPart {
        // Check for image bombs or malicious images
        let imageCheck = checkImageSafety(content, mimeType: part.mediaType)
        
        var warnings: [String] = []
        
        if !imageCheck.isSafe {
            warnings.append("Image safety check failed: \(imageCheck.reason ?? "Unknown")")
            
            // Don't process unsafe images
            return ProcessedPart(
                partId: part.partId,
                content: content,
                processedContent: nil,
                mediaType: part.mediaType,
                isSafe: false,
                warnings: warnings
            )
        }
        
        // Optionally resize large images
        var processedData = content
        if content.count > 1024 * 1024 { // > 1MB
            if let resized = resizeImage(content, maxSize: 1024 * 1024) {
                processedData = resized
                warnings.append("Image resized for performance")
            }
        }
        
        return ProcessedPart(
            partId: part.partId,
            content: content,
            processedContent: processedData,
            mediaType: part.mediaType,
            isSafe: true,
            warnings: warnings
        )
    }
    
    // MARK: - Helper Methods
    
    private func escapeHtml(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    private func autoLinkText(_ html: String) -> String {
        var result = html
        
        // Auto-link URLs
        let urlPattern = #"(https?://[^\s<]+)"#
        result = result.replacingOccurrences(
            of: urlPattern,
            with: "<a href=\"$1\" target=\"_blank\" rel=\"noopener noreferrer\">$1</a>",
            options: .regularExpression
        )
        
        // Auto-link email addresses
        let emailPattern = #"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"#
        result = result.replacingOccurrences(
            of: emailPattern,
            with: "<a href=\"mailto:$1\">$1</a>",
            options: .regularExpression
        )
        
        return result
    }
    
    private func convertEnrichedToHtml(_ enriched: String) -> String {
        // Basic enriched text to HTML conversion
        var html = enriched
        
        // Convert enriched text tags to HTML
        html = html.replacingOccurrences(of: "<bold>", with: "<strong>")
        html = html.replacingOccurrences(of: "</bold>", with: "</strong>")
        html = html.replacingOccurrences(of: "<italic>", with: "<em>")
        html = html.replacingOccurrences(of: "</italic>", with: "</em>")
        html = html.replacingOccurrences(of: "<underline>", with: "<u>")
        html = html.replacingOccurrences(of: "</underline>", with: "</u>")
        
        return html
    }
    
    private func addCSPMetaTag(to html: String) -> String {
        let csp = """
            <meta http-equiv="Content-Security-Policy" content="default-src 'self'; \
            script-src 'none'; object-src 'none'; base-uri 'none'; \
            img-src 'self' data: https:; style-src 'self' 'unsafe-inline';">
            """
        
        // Insert after <head> tag
        if let headRange = html.range(of: "<head>", options: .caseInsensitive) {
            var result = html
            result.insert(contentsOf: csp, at: headRange.upperBound)
            return result
        }
        
        // Or at the beginning if no head tag
        return csp + html
    }
    
    private func validateHTML(_ html: String) -> (isValid: Bool, errors: [String]) {
        var errors: [String] = []
        
        // Check for common XSS patterns
        let dangerousPatterns = [
            "javascript:",
            "vbscript:",
            "onload=",
            "onerror=",
            "onclick=",
            "<script",
            "eval(",
            "document.write",
            "innerHTML"
        ]
        
        for pattern in dangerousPatterns {
            if html.lowercased().contains(pattern) {
                errors.append("Potentially dangerous pattern found: \(pattern)")
            }
        }
        
        return (errors.isEmpty, errors)
    }
    
    private func checkImageSafety(_ data: Data, mimeType: String) -> (isSafe: Bool, reason: String?) {
        // Check image dimensions to prevent decompression bombs
        // This is a simplified check - real implementation would parse image headers
        
        if data.count > 50 * 1024 * 1024 { // > 50MB
            return (false, "Image too large")
        }
        
        // Check for suspicious patterns in image data
        // (In practice, use proper image parsing libraries)
        
        return (true, nil)
    }
    
    private func resizeImage(_ data: Data, maxSize: Int) -> Data? {
        // This would use image processing libraries to resize
        // For now, return nil (no resizing)
        return nil
    }
}

// MARK: - HTML Sanitizer

private class HTMLSanitizer {
    let policy: SecureMailPartHandler.SecurityPolicy
    
    init(policy: SecureMailPartHandler.SecurityPolicy) {
        self.policy = policy
    }
    
    func removeScripts(_ html: String) -> String {
        // Remove script tags and their contents
        let pattern = #"<script[^>]*>.*?</script>"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func removeEventHandlers(_ html: String) -> String {
        // Remove on* event handlers
        let pattern = #"\s+on\w+\s*=\s*["'][^"']*["']"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func removeForms(_ html: String) -> String {
        let pattern = #"<form[^>]*>.*?</form>"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func removeIframes(_ html: String) -> String {
        let pattern = #"<iframe[^>]*>.*?</iframe>"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func removeInlineStyles(_ html: String) -> String {
        let pattern = #"\s+style\s*=\s*["'][^"']*["']"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func removeExternalStylesheets(_ html: String) -> String {
        let pattern = #"<link[^>]*stylesheet[^>]*>"#
        return html.replacingOccurrences(
            of: pattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func blockExternalImages(_ html: String) -> (String, Bool) {
        var blocked = false
        let pattern = #"<img[^>]*src=["']https?://[^"']*["'][^>]*>"#
        
        let result = html.replacingOccurrences(
            of: pattern,
            with: "<img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==\" alt=\"[External Image Blocked]\">",
            options: [.regularExpression, .caseInsensitive]
        )
        
        if result != html {
            blocked = true
        }
        
        return (result, blocked)
    }
    
    func proxifyImages(_ html: String) -> String {
        // Replace external image URLs with proxy URLs
        let pattern = #"src=["'](https?://[^"']+)["']"#
        return html.replacingOccurrences(
            of: pattern,
            with: "src=\"/proxy?url=$1\"",
            options: [.regularExpression, .caseInsensitive]
        )
    }
    
    func sanitizeLinks(_ html: String, allowedDomains: Set<String>) -> String {
        var result = html
        
        // Add target="_blank" and rel="noopener noreferrer" to external links
        let pattern = #"<a\s+([^>]*href=["'][^"']+["'][^>]*)>"#
        result = result.replacingOccurrences(
            of: pattern,
            with: "<a $1 target=\"_blank\" rel=\"noopener noreferrer\">",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove links to disallowed domains if specified
        if !allowedDomains.isEmpty {
            // Implementation would check each link against allowed domains
        }
        
        return result
    }
}

// MARK: - Supporting Types

struct ProcessedPart {
    let partId: String
    let content: Data
    let processedContent: Data?
    let mediaType: String
    let isSafe: Bool
    let warnings: [String]
}

enum ProcessingError: Error {
    case contentTooLarge
    case invalidEncoding
    case processingFailed(String)
}
