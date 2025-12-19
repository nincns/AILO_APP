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
