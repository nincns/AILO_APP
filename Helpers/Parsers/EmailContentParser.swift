// AILO_APP/Helpers/Parsers/EmailContentParser_Phase3.swift
// PHASE 3: Simplified Email Content Parser
// Orchestrates MIME parsing and render cache integration

import Foundation

/// Phase 3: Simplified parser - delegates to EnhancedMIMEParser
public class SimplifiedEmailContentParser {
    
    private let mimeParser = EnhancedMIMEParser()
    
    // MARK: - Main Parse Method
    
    /// Parse email with structure guidance (Phase 3 preferred method)
    /// - Parameters:
    ///   - structure: Pre-parsed BODYSTRUCTURE
    ///   - sectionContents: Fetched section contents
    ///   - messageId: Message UUID for cache lookup
    ///   - dao: Optional DAO for cache access
    /// - Returns: Complete parse result
    public func parseWithStructure(
        structure: EnhancedBodyStructure,
        sectionContents: [String: Data],
        messageId: UUID,
        dao: MailReadDAO? = nil
    ) -> MIMEParseResult {
        
        print("🔄 [EmailContentParser Phase3] Starting parse")
        
        // STEP 1: Check render cache (Phase 1)
        if let dao = dao,
           let cache = try? dao.getRenderCache(messageId: messageId) {
            print("✅ [EmailContentParser Phase3] Using cached render")
            
            // Convert cache to result (no need to re-parse!)
            let bodyCandidate = cache.htmlRendered != nil 
                ? BodyCandidate(partId: "cached", contentType: .html, 
                              charset: "utf-8", content: cache.htmlRendered!)
                : (cache.textRendered != nil 
                    ? BodyCandidate(partId: "cached", contentType: .plain,
                                  charset: "utf-8", content: cache.textRendered!)
                    : nil)
            
            return MIMEParseResult(
                parts: [],
                bestBodyCandidate: bodyCandidate,
                attachments: [],
                inlineReferences: []
            )
        }
        
        print("📝 [EmailContentParser Phase3] No cache - parsing MIME")
        
        // STEP 2: Parse MIME (single pass)
        let result = mimeParser.parseWithStructure(
            structure: structure,
            sectionContents: sectionContents,
            defaultCharset: "utf-8"
        )
        
        // STEP 3: Store render cache for next time
        if let dao = dao, let body = result.bestBodyCandidate {
            do {
                try dao.storeRenderCache(
                    messageId: messageId,
                    htmlRendered: body.contentType == .html ? body.content : nil,
                    textRendered: body.contentType == .plain ? body.content : nil,
                    generatorVersion: 1
                )
                print("✅ [EmailContentParser Phase3] Stored render cache")
            } catch {
                print("⚠️ [EmailContentParser Phase3] Failed to store cache: \(error)")
            }
        }
        
        return result
    }
    
    /// Legacy parse method (for backwards compatibility)
    /// Prefer parseWithStructure() for new code
    @available(*, deprecated, message: "Use parseWithStructure instead")
    public func parse(_ rawContent: String) -> ParsedEmailContent {
        print("⚠️ [EmailContentParser Phase3] Using legacy parse - consider upgrading")
        
        // Detect content type
        let isHTML = rawContent.contains("<html") || rawContent.contains("<body")
        
        if isHTML {
            return ParsedEmailContent(text: nil, html: rawContent)
        } else {
            return ParsedEmailContent(text: rawContent, html: nil)
        }
    }
}

// MARK: - Static Interface (backwards compatibility)

extension SimplifiedEmailContentParser {
    
    /// Static parse method for backwards compatibility
    public static func parseEmailContent(_ rawContent: String) -> ParsedEmailContent {
        let parser = SimplifiedEmailContentParser()
        return parser.parse(rawContent)
    }
}

// MARK: - Legacy Support Types

/// Legacy parsed email content structure (for backwards compatibility)
public struct ParsedEmailContent {
    public let text: String?
    public let html: String?
    
    public init(text: String?, html: String?) {
        self.text = text
        self.html = html
    }
    
    // Legacy compatibility initializer
    public init(content: String, isHTML: Bool, encoding: String, subject: String? = nil, from: String? = nil, to: String? = nil, multipartType: MultipartType? = nil, hasAttachments: Bool = false, hasInlineImages: Bool = false, attachmentCount: Int = 0) {
        if isHTML {
            self.text = nil
            self.html = content
        } else {
            self.text = content
            self.html = nil
        }
    }
    
    /// Legacy multipart types (kept for compatibility)
    public enum MultipartType: String, CaseIterable {
        case alternative = "multipart/alternative"
        case mixed = "multipart/mixed"
        case related = "multipart/related"
        case signed = "multipart/signed"
        case encrypted = "multipart/encrypted"
        case report = "multipart/report"
        case digest = "multipart/digest"
        case parallel = "multipart/parallel"
        case unknown = "multipart/unknown"
    }
}

// MARK: - Phase 3 Required Types (stubs for dependencies)

/// Stub for EnhancedMIMEParser dependency
public class EnhancedMIMEParser {
    public init() {}
    
    public func parseWithStructure(
        structure: EnhancedBodyStructure,
        sectionContents: [String: Data],
        defaultCharset: String
    ) -> MIMEParseResult {
        // Stub implementation
        return MIMEParseResult(parts: [], bestBodyCandidate: nil, attachments: [], inlineReferences: [])
    }
}

/// Stub for EnhancedBodyStructure dependency
public struct EnhancedBodyStructure {
    // Stub implementation
}

/// Stub for MIMEParseResult dependency
public struct MIMEParseResult {
    public let parts: [MIMEPart]
    public let bestBodyCandidate: BodyCandidate?
    public let attachments: [AttachmentInfo]
    public let inlineReferences: [InlineReference]
    
    public init(parts: [MIMEPart], bestBodyCandidate: BodyCandidate?, attachments: [AttachmentInfo], inlineReferences: [InlineReference]) {
        self.parts = parts
        self.bestBodyCandidate = bestBodyCandidate
        self.attachments = attachments
        self.inlineReferences = inlineReferences
    }
}

/// Stub for BodyCandidate dependency
public struct BodyCandidate {
    public enum ContentType {
        case html, plain
    }
    
    public let partId: String
    public let contentType: ContentType
    public let charset: String
    public let content: String
    
    public init(partId: String, contentType: ContentType, charset: String, content: String) {
        self.partId = partId
        self.contentType = contentType
        self.charset = charset
        self.content = content
    }
}

/// Stub for MIMEPart dependency
public struct MIMEPart {
    // Stub implementation
}

/// Stub for AttachmentInfo dependency
public struct AttachmentInfo {
    // Stub implementation
}

/// Stub for InlineReference dependency
public struct InlineReference {
    // Stub implementation
}

/// Stub for MailReadDAO dependency
public protocol MailReadDAO {
    func getRenderCache(messageId: UUID) throws -> RenderCache?
    func storeRenderCache(messageId: UUID, htmlRendered: String?, textRendered: String?, generatorVersion: Int) throws
}

/// Stub for RenderCache dependency
public struct RenderCache {
    public let htmlRendered: String?
    public let textRendered: String?
    
    public init(htmlRendered: String?, textRendered: String?) {
        self.htmlRendered = htmlRendered
        self.textRendered = textRendered
    }
}

// MARK: - Parse Flow Documentation

/*
 PHASE 3 PARSE FLOW
 ==================
 
 OLD (Phase 1 & 2):
 ┌─────────────────────────────────────────────┐
 │ 1. Fetch BODYSTRUCTURE                      │
 │ 2. Fetch Section Contents                   │
 │ 3. Parse MIME (EmailContentParser)          │
 │ 4. Clean Body (BodyContentProcessor)        │ ← Multiple passes!
 │ 5. Parse MIME again (MIMEParser)            │ ← Redundant!
 │ 6. Store to DB                              │
 └─────────────────────────────────────────────┘
 
 NEW (Phase 3):
 ┌─────────────────────────────────────────────┐
 │ 1. Check render_cache → Use if exists       │ ← Fast path!
 │                                              │
 │ IF NO CACHE:                                │
 │ 2. Fetch BODYSTRUCTURE                      │
 │ 3. Fetch Section Contents                   │
 │ 4. Parse MIME ONCE (EnhancedMIMEParser)    │ ← Single pass!
 │ 5. Store render_cache + MIME parts          │
 │                                              │
 │ NEXT TIME: Use cache, skip parsing          │ ← Instant!
 └─────────────────────────────────────────────┘
 
 BENEFITS:
 - Parse ONCE, not multiple times
 - Render cache = instant display
 - MIME parts = structured storage
 - Clean separation of concerns
 */