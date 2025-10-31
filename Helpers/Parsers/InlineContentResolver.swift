// InlineContentResolver.swift - Resolves cid: URLs and embeds inline content
import Foundation

/// Resolves Content-ID references and embeds inline content in HTML emails
public class InlineContentResolver {
    
    /// Represents inline content that can be embedded
    public struct InlineContent {
        let contentId: String
        let mimeType: String
        let data: Data
        let filename: String?
        
        /// Generate data URL for embedding
        var dataURL: String {
            let base64Data = data.base64EncodedString()
            return "data:\(mimeType);base64,\(base64Data)"
        }
        
        /// Check if content is an image
        var isImage: Bool {
            return mimeType.lowercased().hasPrefix("image/")
        }
    }
    
    /// Enhanced MIME part for inline content resolution
    public struct EnhancedMIMEPart {
        let contentType: String
        let content: String
        let contentId: String?
        let filename: String?
        let isInline: Bool
        let data: Data
        let headers: [String: String]
        let charset: String?
        
        public init(contentType: String, content: String, contentId: String? = nil, filename: String? = nil, isInline: Bool = false, data: Data = Data(), headers: [String: String] = [:], charset: String? = nil) {
            self.contentType = contentType
            self.content = content
            self.contentId = contentId
            self.filename = filename
            self.isInline = isInline
            self.data = data
            self.headers = headers
            self.charset = charset
        }
    }
    
    /// Content-ID to content mapping
    private var contentMap: [String: InlineContent] = [:]
    
    /// Initialize resolver with multipart parts
    public init(parts: [EnhancedMIMEPart]) {
        buildContentMap(from: parts)
    }
    
    /// Build Content-ID to content mapping
    private func buildContentMap(from parts: [EnhancedMIMEPart]) {
        for part in parts {
            // Only process inline parts with Content-ID
            guard part.isInline, let contentId = part.contentId else { continue }
            
            // Convert content string to data (assuming it's base64 encoded for binary content)
            let contentData = decodePartContent(part)
            
            // Get MIME type
            let mimeType = part.contentType ?? "application/octet-stream"
            
            let inlineContent = InlineContent(
                contentId: contentId,
                mimeType: mimeType,
                data: contentData,
                filename: part.filename
            )
            
            contentMap[contentId] = inlineContent
        }
    }
    
    /// Decode part content to Data
    private func decodePartContent(_ part: EnhancedMIMEPart) -> Data {
        let content = part.content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check transfer encoding from headers
        let transferEncoding = part.headers["content-transfer-encoding"]?.lowercased() 
            ?? part.headers["Content-Transfer-Encoding"]?.lowercased()
        
        switch transferEncoding {
        case "base64":
            return Data(base64Encoded: content) ?? Data()
        case "quoted-printable":
            // Use ContentDecoder for comprehensive quoted-printable decoding
            let decoded = ContentDecoder.decodeQuotedPrintable(content)
            return decoded.data(using: String.Encoding.utf8) ?? Data()
        case "7bit", "8bit":
            // Handle character encoding conversion if charset is specified
            if let charset = part.charset?.lowercased(), charset != "utf-8" {
                // Convert from specified charset to UTF-8
                return ContentDecoder.convertCharset(content, from: charset).data(using: .utf8) ?? Data()
            }
            return content.data(using: String.Encoding.utf8) ?? Data()
        default:
            // Try to detect and decode automatically using ContentDecoder
            let decoded = ContentDecoder.decodeMultipleEncodings(content)
            return decoded.data(using: String.Encoding.utf8) ?? Data()
        }
    }
    
    /// Resolve all cid: URLs in HTML content
    public func resolveInlineContent(_ htmlContent: String) -> String {
        var resolvedHTML = htmlContent
        
        // Find all cid: references
        let cidReferences = findCIDReferences(in: htmlContent)
        
        for cidRef in cidReferences {
            if let inlineContent = contentMap[cidRef.contentId] {
                resolvedHTML = resolvedHTML.replacingOccurrences(
                    of: cidRef.fullURL,
                    with: inlineContent.dataURL
                )
            } else {
                // Replace with placeholder for missing content
                resolvedHTML = resolvedHTML.replacingOccurrences(
                    of: cidRef.fullURL,
                    with: "data:image/svg+xml;base64,\(createPlaceholderSVG())"
                )
            }
        }
        
        return resolvedHTML
    }
    
    /// Find all cid: references in HTML
    private func findCIDReferences(in html: String) -> [CIDReference] {
        var references: [CIDReference] = []
        
        // Pattern for cid: URLs in various contexts
        let patterns = [
            #"src=["\']cid:([^"\']+)["\']"#,      // img src="cid:..."
            #"href=["\']cid:([^"\']+)["\']"#,     // a href="cid:..."
            #"url\(cid:([^)]+)\)"#,               // CSS url(cid:...)
            #"cid:([a-zA-Z0-9@._-]+)"#            // General cid: pattern
        ]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = regex.matches(in: html, options: [], range: range)
            
            for match in matches {
                if let fullRange = Range(match.range, in: html),
                   match.numberOfRanges > 1,
                   let cidRange = Range(match.range(at: 1), in: html) {
                    
                    let fullURL = String(html[fullRange])
                    let contentId = String(html[cidRange])
                    
                    let reference = CIDReference(
                        contentId: contentId,
                        fullURL: fullURL,
                        context: detectContext(fullURL)
                    )
                    
                    references.append(reference)
                }
            }
        }
        
        return Array(Set(references)) // Remove duplicates
    }
    
    /// Detect the context of a CID reference
    private func detectContext(_ fullURL: String) -> CIDContext {
        let lowercased = fullURL.lowercased()
        
        if lowercased.contains("src=") {
            return .imageSrc
        } else if lowercased.contains("href=") {
            return .link
        } else if lowercased.contains("url(") {
            return .cssURL
        } else {
            return .unknown
        }
    }
    
    /// Create placeholder SVG for missing images
    private func createPlaceholderSVG() -> String {
        let svg = """
        <svg width="100" height="100" xmlns="http://www.w3.org/2000/svg">
            <rect width="100" height="100" fill="#f0f0f0" stroke="#ccc"/>
            <text x="50" y="55" text-anchor="middle" fill="#666" font-size="12">Image</text>
        </svg>
        """
        return svg.data(using: String.Encoding.utf8)?.base64EncodedString() ?? ""
    }
    
    /// Get statistics about inline content resolution
    public func getResolutionStats(_ htmlContent: String) -> ResolutionStats {
        let cidReferences = findCIDReferences(in: htmlContent)
        let resolvedCount = cidReferences.filter { contentMap[$0.contentId] != nil }.count
        
        return ResolutionStats(
            totalReferences: cidReferences.count,
            resolvedReferences: resolvedCount,
            missingReferences: cidReferences.count - resolvedCount,
            availableInlineContent: contentMap.count
        )
    }
    
    /// Get all available inline content
    public func getAvailableContent() -> [String: InlineContent] {
        return contentMap
    }
    
    /// Static method for quick resolution
    public static func resolveInlineContent(
        in htmlContent: String,
        using parts: [EnhancedMIMEPart]
    ) -> String {
        let resolver = InlineContentResolver(parts: parts)
        return resolver.resolveInlineContent(htmlContent)
    }
    
    /// Static method for decoding message body content with proper transfer encoding
    public static func decodeMessageBody(
        _ content: String,
        transferEncoding: String?,
        charset: String?
    ) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = transferEncoding?.lowercased()
        
        switch encoding {
        case "quoted-printable":
            return ContentDecoder.decodeQuotedPrintable(trimmedContent)
        case "base64":
            if let data = Data(base64Encoded: trimmedContent),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            return trimmedContent
        case "7bit", "8bit":
            // Handle charset conversion if needed
            if let charset = charset?.lowercased(), charset != "utf-8" {
                return ContentDecoder.convertCharset(trimmedContent, from: charset)
            }
            return trimmedContent
        default:
            // Try automatic detection and decoding
            return ContentDecoder.decodeMultipleEncodings(trimmedContent)
        }
    }
    
    /// Test method
    public static func test() {
        print("🧪 Testing InlineContentResolver...")
        
        // Create test parts
        let testHTML = """
        <html>
        <body>
            <p>Hello!</p>
            <img src="cid:image001@example.com" alt="Test Image">
            <p>Background: <div style="background: url(cid:bg001)"></div></p>
        </body>
        </html>
        """
        
        // Mock enhanced MIME parts
        let mockPart = EnhancedMIMEPart(
            contentType: "image/png",
            content: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==",
            contentId: "image001@example.com",
            filename: "test.png",
            isInline: true,
            data: Data()
        )
        
        let resolver = InlineContentResolver(parts: [mockPart])
        let resolvedHTML = resolver.resolveInlineContent(testHTML)
        let stats = resolver.getResolutionStats(testHTML)
        
        print("Original CID references: \(stats.totalReferences)")
        print("Resolved references: \(stats.resolvedReferences)")
        print("Missing references: \(stats.missingReferences)")
        print("HTML contains data URLs: \(resolvedHTML.contains("data:"))")
        
        print("✅ InlineContentResolver tests completed")
    }
}

// MARK: - Supporting Types

/// Represents a CID reference found in HTML
public struct CIDReference: Hashable {
    let contentId: String
    let fullURL: String
    let context: CIDContext
}

/// Context where CID reference was found
public enum CIDContext {
    case imageSrc      // <img src="cid:...">
    case link          // <a href="cid:...">
    case cssURL        // url(cid:...)
    case unknown       // Other contexts
}

/// Statistics about inline content resolution
public struct ResolutionStats {
    let totalReferences: Int
    let resolvedReferences: Int
    let missingReferences: Int
    let availableInlineContent: Int
    
    var resolutionRate: Double {
        guard totalReferences > 0 else { return 1.0 }
        return Double(resolvedReferences) / Double(totalReferences)
    }
}

// MARK: - Integration Extension

extension InlineContentResolver {
    
    /// Advanced resolution with fallback handling
    public func resolveWithFallbacks(_ htmlContent: String, enablePlaceholders: Bool = true) -> String {
        var resolvedHTML = htmlContent
        let cidReferences = findCIDReferences(in: htmlContent)
        
        for cidRef in cidReferences {
            if let inlineContent = contentMap[cidRef.contentId] {
                // Successful resolution
                resolvedHTML = resolvedHTML.replacingOccurrences(
                    of: cidRef.fullURL,
                    with: inlineContent.dataURL
                )
            } else if enablePlaceholders {
                // Create contextual placeholder
                let placeholder = createContextualPlaceholder(for: cidRef.context)
                resolvedHTML = resolvedHTML.replacingOccurrences(
                    of: cidRef.fullURL,
                    with: placeholder
                )
            } else {
                // Remove the reference entirely
                resolvedHTML = resolvedHTML.replacingOccurrences(
                    of: cidRef.fullURL,
                    with: ""
                )
            }
        }
        
        return resolvedHTML
    }
    
    /// Create contextual placeholder based on CID context
    private func createContextualPlaceholder(for context: CIDContext) -> String {
        switch context {
        case .imageSrc:
            return "data:image/svg+xml;base64,\(createPlaceholderSVG())"
        case .link:
            return "#missing-content"
        case .cssURL:
            return "none"
        case .unknown:
            return ""
        }
    }
}