// AILO_APP/Core/Mail/MailContentRenderer.swift
// Phase 5: Optimized content rendering using stored metadata
// No re-parsing, direct display based on content_type from database

import Foundation
import SwiftUI
import WebKit

/// Phase 5: Renders mail content using stored metadata without re-processing
public class MailContentRenderer {
    
    /// Render options for content display
    public struct RenderOptions {
        public let allowExternalImages: Bool
        public let blockRemoteContent: Bool
        public let showInlineAttachments: Bool
        public let maxImageWidth: Int
        public let sanitizeHTML: Bool
        
        public static let `default` = RenderOptions(
            allowExternalImages: false,
            blockRemoteContent: true,
            showInlineAttachments: true,
            maxImageWidth: 800,
            sanitizeHTML: true
        )
        
        public init(allowExternalImages: Bool = false, blockRemoteContent: Bool = true,
                    showInlineAttachments: Bool = true, maxImageWidth: Int = 800,
                    sanitizeHTML: Bool = true) {
            self.allowExternalImages = allowExternalImages
            self.blockRemoteContent = blockRemoteContent
            self.showInlineAttachments = showInlineAttachments
            self.maxImageWidth = maxImageWidth
            self.sanitizeHTML = sanitizeHTML
        }
    }
    
    // MARK: - Content Rendering (Phase 5)
    
    /// Render content using stored metadata - no re-parsing needed
    public static func renderContent(
        bodyEntity: MessageBodyEntity,
        attachments: [AttachmentEntity] = [],
        options: RenderOptions = .default
    ) -> RenderedMailContent {
        
        print("📄 DEBUG: Rendering content using stored metadata:")
        print("   - Content-Type: \(bodyEntity.contentType ?? "unknown")")
        print("   - Charset: \(bodyEntity.charset ?? "unknown")")
        print("   - Is Multipart: \(bodyEntity.isMultipart)")
        print("   - Has Attachments: \(bodyEntity.hasAttachments)")
        
        // Phase 5: Use stored metadata to determine rendering strategy
        let contentType = bodyEntity.contentType?.lowercased() ?? "text/plain"
        let charset = bodyEntity.charset ?? "utf-8"
        
        if contentType.contains("html") {
            return renderHTMLContent(
                html: bodyEntity.html,
                text: bodyEntity.text,
                attachments: attachments,
                charset: charset,
                options: options
            )
        } else {
            return renderTextContent(
                text: bodyEntity.text ?? bodyEntity.html ?? "",
                attachments: attachments,
                charset: charset,
                options: options
            )
        }
    }
    
    /// Render HTML content with inline attachments
    private static func renderHTMLContent(
        html: String?,
        text: String?,
        attachments: [AttachmentEntity],
        charset: String,
        options: RenderOptions
    ) -> RenderedMailContent {
        
        guard var htmlContent = html ?? text else {
            return RenderedMailContent(
                content: "No content available",
                contentType: .text,
                attachments: attachments,
                warnings: ["No HTML content found"]
            )
        }
        
        var warnings: [String] = []
        
        // Phase 5: Process inline attachments using stored metadata
        if options.showInlineAttachments {
            let inlineAttachments = attachments.filter { $0.isInline }
            htmlContent = processInlineAttachments(
                html: htmlContent,
                inlineAttachments: inlineAttachments,
                warnings: &warnings
            )
        }
        
        // Apply security and display optimizations
        if options.sanitizeHTML {
            htmlContent = sanitizeHTML(htmlContent, options: options, warnings: &warnings)
        }
        
        // Add responsive CSS
        htmlContent = wrapWithResponsiveCSS(htmlContent, maxImageWidth: options.maxImageWidth)
        
        return RenderedMailContent(
            content: htmlContent,
            contentType: .html,
            attachments: attachments,
            warnings: warnings
        )
    }
    
    /// Render plain text content
    private static func renderTextContent(
        text: String,
        attachments: [AttachmentEntity],
        charset: String,
        options: RenderOptions
    ) -> RenderedMailContent {
        
        // Convert plain text to HTML for consistent display
        let htmlContent = convertTextToHTML(text, charset: charset)
        
        return RenderedMailContent(
            content: htmlContent,
            contentType: .text,
            attachments: attachments,
            warnings: []
        )
    }
    
    // MARK: - HTML Processing
    
    /// Process inline attachments using Phase 4 metadata
    private static func processInlineAttachments(
        html: String,
        inlineAttachments: [AttachmentEntity],
        warnings: inout [String]
    ) -> String {
        
        var processedHTML = html
        
        for attachment in inlineAttachments {
            guard let contentId = attachment.contentId else {
                warnings.append("Inline attachment \(attachment.filename) missing content-id")
                continue
            }
            
            // Replace cid: references with data URLs
            let cidPattern = "cid:\(contentId)"
            
            if processedHTML.contains(cidPattern) {
                // Phase 4: Get attachment data (from file or database)
                if let data = getAttachmentData(attachment) {
                    let dataURL = "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
                    processedHTML = processedHTML.replacingOccurrences(of: cidPattern, with: dataURL)
                    print("✅ DEBUG: Processed inline attachment: \(attachment.filename)")
                } else {
                    warnings.append("Failed to load data for inline attachment: \(attachment.filename)")
                    // Replace with placeholder
                    let placeholder = "data:image/svg+xml;base64,\(createPlaceholderSVG(filename: attachment.filename))"
                    processedHTML = processedHTML.replacingOccurrences(of: cidPattern, with: placeholder)
                }
            }
        }
        
        return processedHTML
    }
    
    /// Phase 4: Get attachment data from file system or database
    private static func getAttachmentData(_ attachment: AttachmentEntity) -> Data? {
        // Try file system first (Phase 4)
        if let filePath = attachment.filePath,
           FileManager.default.fileExists(atPath: filePath) {
            return try? Data(contentsOf: URL(fileURLWithPath: filePath))
        }
        
        // Fallback to database
        return attachment.data
    }
    
    /// Sanitize HTML for security and display
    private static func sanitizeHTML(_ html: String, options: RenderOptions, warnings: inout [String]) -> String {
        var sanitized = html
        
        // Remove potentially dangerous elements
        let dangerousElements = [
            "<script[^>]*>.*?</script>",
            "<iframe[^>]*>.*?</iframe>",
            "<object[^>]*>.*?</object>",
            "<embed[^>]*>.*?</embed>",
            "<form[^>]*>.*?</form>",
            "javascript:",
            "data:text/html"
        ]
        
        for pattern in dangerousElements {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            if let regex = regex {
                let range = NSRange(location: 0, length: sanitized.utf16.count)
                let matches = regex.matches(in: sanitized, options: [], range: range)
                if matches.count > 0 {
                    warnings.append("Removed \(matches.count) potentially dangerous elements")
                    sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
                }
            }
        }
        
        // Block remote content if requested
        if options.blockRemoteContent {
            sanitized = blockRemoteImages(sanitized, warnings: &warnings)
        }
        
        return sanitized
    }
    
    /// Block remote images for privacy
    private static func blockRemoteImages(_ html: String, warnings: inout [String]) -> String {
        let pattern = #"<img([^>]*)\s+src\s*=\s*["']https?://[^"']*["']([^>]*)>"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        
        let range = NSRange(location: 0, length: html.utf16.count)
        let matches = regex.matches(in: html, options: [], range: range)
        
        if matches.count > 0 {
            warnings.append("Blocked \(matches.count) remote images for privacy")
            
            let blockedHTML = regex.stringByReplacingMatches(
                in: html,
                options: [],
                range: range,
                withTemplate: """
                <div style="border: 1px solid #ccc; padding: 10px; margin: 5px 0; background: #f5f5f5; text-align: center; color: #666;">
                    <p>🔒 Remote image blocked for privacy</p>
                    <small>Click "Load Images" to display external content</small>
                </div>
                """
            )
            
            return blockedHTML
        }
        
        return html
    }
    
    /// Wrap content with responsive CSS
    private static func wrapWithResponsiveCSS(_ content: String, maxImageWidth: Int) -> String {
        let css = """
        <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
            line-height: 1.6;
            color: #333;
            max-width: 100%;
            margin: 0;
            padding: 16px;
            word-wrap: break-word;
        }
        
        img {
            max-width: \(maxImageWidth)px !important;
            width: auto !important;
            height: auto !important;
            border-radius: 4px;
        }
        
        table {
            max-width: 100% !important;
            border-collapse: collapse;
        }
        
        td, th {
            padding: 8px;
            text-align: left;
        }
        
        a {
            color: #007AFF;
            text-decoration: none;
        }
        
        a:hover {
            text-decoration: underline;
        }
        
        pre {
            background: #f5f5f5;
            padding: 12px;
            border-radius: 4px;
            overflow-x: auto;
            font-family: 'SF Mono', Consolas, monospace;
        }
        
        blockquote {
            border-left: 4px solid #007AFF;
            margin: 16px 0;
            padding: 12px 16px;
            background: #f8f9ff;
        }
        
        @media (prefers-color-scheme: dark) {
            body { color: #fff; background: #1c1c1e; }
            pre { background: #2c2c2e; color: #fff; }
            blockquote { background: #1a1a2e; }
        }
        </style>
        """
        
        // Wrap content if it doesn't already have HTML structure
        if !content.lowercased().contains("<html>") {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                \(css)
            </head>
            <body>
                \(content)
            </body>
            </html>
            """
        } else {
            // Insert CSS into existing HTML
            return content.replacingOccurrences(of: "</head>", with: "\(css)</head>")
        }
    }
    
    /// Convert plain text to HTML
    private static func convertTextToHTML(_ text: String, charset: String) -> String {
        // Escape HTML entities
        var html = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
        
        // Convert line breaks to <br>
        html = html.replacingOccurrences(of: "\n", with: "<br>")
        
        // Convert URLs to clickable links
        html = linkifyURLs(html)
        
        // Wrap in HTML structure
        return wrapWithResponsiveCSS(html, maxImageWidth: 800)
    }
    
    /// Convert URLs to clickable links
    private static func linkifyURLs(_ text: String) -> String {
        let pattern = #"https?://[^\s<>"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: #"<a href="$0" target="_blank">$0</a>"#
        )
    }
    
    /// Create placeholder SVG for missing inline images
    private static func createPlaceholderSVG(filename: String) -> String {
        let svg = """
        <svg width="200" height="100" xmlns="http://www.w3.org/2000/svg">
            <rect width="200" height="100" fill="#f0f0f0" stroke="#ccc"/>
            <text x="100" y="45" text-anchor="middle" fill="#666" font-size="12">Missing Image</text>
            <text x="100" y="65" text-anchor="middle" fill="#999" font-size="10">\(filename)</text>
        </svg>
        """
        
        return Data(svg.utf8).base64EncodedString()
    }
}

// MARK: - Supporting Types

/// Rendered mail content with metadata
public struct RenderedMailContent {
    public let content: String
    public let contentType: ContentDisplayType
    public let attachments: [AttachmentEntity]
    public let warnings: [String]
    
    public var hasWarnings: Bool { !warnings.isEmpty }
    
    public enum ContentDisplayType {
        case text
        case html
    }
}

/// Content statistics for debugging
public struct ContentStats {
    public let originalSize: Int
    public let processedSize: Int
    public let inlineAttachments: Int
    public let warnings: Int
    public let renderTime: TimeInterval
    
    public var compressionRatio: Double {
        guard originalSize > 0 else { return 0 }
        return Double(processedSize) / Double(originalSize)
    }
}

// MARK: - Performance Monitoring

/// Performance monitor for content rendering
public class MailRenderingPerformanceMonitor {
    private static var renderTimes: [TimeInterval] = []
    private static let maxSamples = 100
    
    public static func recordRenderTime(_ time: TimeInterval) {
        renderTimes.append(time)
        if renderTimes.count > maxSamples {
            renderTimes.removeFirst()
        }
    }
    
    public static func getAverageRenderTime() -> TimeInterval {
        guard !renderTimes.isEmpty else { return 0 }
        return renderTimes.reduce(0, +) / Double(renderTimes.count)
    }
    
    public static func getPerformanceStats() -> (min: TimeInterval, max: TimeInterval, avg: TimeInterval) {
        guard !renderTimes.isEmpty else { return (0, 0, 0) }
        return (
            min: renderTimes.min() ?? 0,
            max: renderTimes.max() ?? 0,
            avg: getAverageRenderTime()
        )
    }
}