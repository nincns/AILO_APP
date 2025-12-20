// AILO_APP/Helpers/Parsers/BodyContentProcessor_Phase3.swift
// PHASE 3: Reduced Body Content Processor
// Only handles final content preparation (no MIME parsing)

import Foundation

/// Phase 3: Lightweight processor for final content preparation
/// No longer responsible for MIME parsing - that's done by MIMEParser
public class StreamlinedBodyContentProcessor {
    
    // MARK: - Content Finalization
    
    /// Prepare HTML for display (final step after MIME parsing)
    /// - Parameters:
    ///   - html: Parsed HTML content (from MIMEParser)
    ///   - inlineRefs: Inline references for cid: rewriting
    ///   - messageId: Message ID for URL generation
    /// - Returns: Finalized HTML ready for WebView
    public static func finalizeHTMLForDisplay(
        _ html: String,
        inlineRefs: [InlineReference],
        messageId: UUID
    ) -> String {
        var content = html
        
        // STEP 1: Rewrite cid: links (Phase 4 preview)
        content = rewriteCidLinks(content, inlineRefs: inlineRefs, messageId: messageId)
        
        // STEP 2: Basic HTML sanitization
        content = sanitizeHTML(content)
        
        // STEP 3: Remove DOCTYPE and meta tags (WebView compatibility)
        content = stripHTMLMetadata(content)
        
        return content
    }
    
    /// Prepare plain text for display
    /// - Parameter text: Parsed plain text (from MIMEParser)
    /// - Returns: Finalized text ready for display
    public static func finalizeTextForDisplay(_ text: String) -> String {
        var content = text
        
        // Normalize line breaks
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")
        
        // Trim excessive whitespace
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return content
    }
    
    // MARK: - CID Rewriting (Phase 4 Preview)
    
    /// Rewrite cid: URLs to app-internal URLs
    /// Example: <img src="cid:image123"> → <img src="/mail/{msgId}/cid/image123">
    private static func rewriteCidLinks(
        _ html: String,
        inlineRefs: [InlineReference],
        messageId: UUID
    ) -> String {
        guard !inlineRefs.isEmpty else { return html }
        
        var result = html
        
        for ref in inlineRefs {
            // Pattern: src="cid:xxx" or src='cid:xxx'
            let patterns = [
                "src=\"cid:\(ref.contentId)\"",
                "src='cid:\(ref.contentId)'",
                "src=cid:\(ref.contentId)"
            ]
            
            let replacement = "src=\"/mail/\(messageId.uuidString)/cid/\(ref.contentId)\""
            
            for pattern in patterns {
                result = result.replacingOccurrences(of: pattern, with: replacement,
                                                    options: .caseInsensitive)
            }
        }
        
        print("🔗 [BodyContentProcessor Phase3] Rewrote \(inlineRefs.count) cid: references")
        
        return result
    }
    
    // MARK: - HTML Sanitization
    
    /// Basic HTML sanitization for WebView
    private static func sanitizeHTML(_ html: String) -> String {
        var content = html
        
        // Remove potentially dangerous tags
        let dangerousTags = ["script", "object", "embed", "applet", "iframe"]
        for tag in dangerousTags {
            // Remove opening and closing tags
            content = content.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            // Remove self-closing tags
            content = content.replacingOccurrences(
                of: "<\(tag)[^>]*/>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Remove event handlers (onclick, onerror, etc.)
        content = content.replacingOccurrences(
            of: "\\son\\w+\\s*=\\s*[\"'][^\"']*[\"']",
            with: "",
            options: .regularExpression
        )
        
        // Remove javascript: URLs
        content = content.replacingOccurrences(
            of: "javascript:",
            with: "",
            options: .caseInsensitive
        )
        
        return content
    }
    
    /// Remove DOCTYPE, meta tags, and other HTML metadata
    private static func stripHTMLMetadata(_ html: String) -> String {
        var content = html
        
        // Remove DOCTYPE
        content = content.replacingOccurrences(
            of: "<!DOCTYPE[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove meta tags
        content = content.replacingOccurrences(
            of: "<meta[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Remove XML declarations
        content = content.replacingOccurrences(
            of: "<\\?xml[^>]*\\?>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return content
    }
    
    // MARK: - Legacy Methods (Deprecated)
    
    /// Legacy HTML cleaning (deprecated)
    @available(*, deprecated, message: "Use finalizeHTMLForDisplay instead")
    public static func cleanHTMLForDisplay(_ html: String) -> String {
        print("⚠️ [BodyContentProcessor Phase3] Using legacy method")
        return finalizeHTMLForDisplay(html, inlineRefs: [], messageId: UUID())
    }
}

// MARK: - Phase 3 Processing Guidelines

/*
 BODY CONTENT PROCESSOR RESPONSIBILITIES (Phase 3)
 =================================================
 
 ❌ NOT RESPONSIBLE FOR:
 - MIME parsing (→ MIMEParser)
 - Quoted-Printable decoding (→ ContentDecoder)
 - Transfer encoding (→ ContentDecoder)
 - Multipart handling (→ MIMEParser)
 - Charset detection (→ MIMEParser)
 - MIME boundary parsing (→ MIMEParser)
 
 ✅ RESPONSIBLE FOR:
 - CID link rewriting (cid: → app URLs)
 - HTML sanitization (XSS prevention)
 - Metadata stripping (DOCTYPE, meta tags)
 - Final formatting for WebView
 
 WHEN TO USE:
 - After MIME parsing is complete
 - Before storing in render_cache
 - Before displaying in UI
 
 EXAMPLE FLOW:
 1. MIMEParser → Parsed content
 2. BodyContentProcessor → Finalize
 3. Store in render_cache
 4. Display in WebView
 */

// MARK: - Backwards Compatibility Wrapper

/// Wrapper for old BodyContentProcessor API
public class BodyContentProcessor {
    
    /// Legacy method - redirects to new implementation
    public static func cleanHTMLForDisplay(_ html: String) -> String {
        return StreamlinedBodyContentProcessor.finalizeHTMLForDisplay(
            html,
            inlineRefs: [],
            messageId: UUID()
        )
    }
}
