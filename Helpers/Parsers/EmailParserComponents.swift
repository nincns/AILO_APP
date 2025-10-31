// EmailParserComponents.swift - Overview of email parser components
import Foundation

/*
 EMAIL PARSER COMPONENTS OVERVIEW
 ================================
 
 This file provides an overview of the email parsing components and their relationships.
 Use this as a reference to avoid naming conflicts and understand the architecture.
 
 CURRENT ACTIVE CLASSES:
 ----------------------
 
 Core Decoding:
 - ContentDecoder                    ✅ Main content decoding orchestrator
 - QuotedPrintableDecoder           ✅ Handles quoted-printable encoding
 - TransferEncodingDecoder          ✅ Handles various transfer encodings
 - HeaderCharsetDetector            ✅ Detects character sets in headers
 - TextEnrichedDecoder              ✅ Handles text/enriched format
 
 MIME Parsing:
 - MIMEParser                       ✅ Main MIME parser
 - EmailMultipartHandler            ✅ Handles multipart content (NEW - use this)
 - EmailFormatFlowedHandler         ✅ Handles format=flowed text (NEW - use this)
 
 Content Processing:
 - EmailContentParser               ✅ Main orchestrator
 - ContentCleaner                   ✅ Content cleaning utilities
 - ContentExtractor                 ✅ Content extraction utilities  
 - ContentAnalyzer                  ✅ Content analysis utilities
 - HTMLEntityDecoder                ✅ HTML entity decoding
 
 DEPRECATED/DUPLICATE CLASSES (DO NOT USE):
 -----------------------------------------
 - MultipartTypeHandler             ❌ DUPLICATE - use EmailMultipartHandler instead
 - MultipartTypeHandler 2           ❌ DUPLICATE - use EmailMultipartHandler instead
 - FormatFlowedHandler 2            ❌ DUPLICATE - use EmailFormatFlowedHandler instead
 - InlineContentResolver            ⚠️  May have conflicts - check before use
 
 NAMING CONVENTIONS:
 ------------------
 - Use "Email" prefix for main parser classes
 - Use "Content" prefix for content processing utilities
 - Use specific descriptive names to avoid conflicts
 
 IMPORT PATTERN:
 --------------
 When working with email parsing, import classes in this order:
 
 1. Core Foundation
 2. ContentDecoder and related decoders
 3. MIMEParser and EmailMultipartHandler
 4. EmailContentParser (main orchestrator)
 
 EXAMPLE USAGE:
 -------------
 
 // Main parsing interface
 let result = EmailContentParser.parseEmailContent(rawEmailContent)
 
 // Direct MIME parsing
 let mimeParser = MIMEParser()
 let mimeContent = mimeParser.parse(rawBodyBytes: nil, rawBodyString: content, ...)
 
 // Content decoding
 let decoded = ContentDecoder.decodeMultipleEncodings(content)
 
 // Text/enriched handling
 if ContentDecoder.isTextEnriched(content) {
     let html = TextEnrichedDecoder.decodeToHTML(content)
 }
 
 // Format=flowed handling
 let flowed = EmailFormatFlowedHandler.processFormatFlowed(content, delSp: false)
 
 */

/// Utility class for email parser component management
public class EmailParserComponents {
    
    /// Get list of active parser classes
    public static var activeClasses: [String] {
        return [
            "ContentDecoder",
            "QuotedPrintableDecoder", 
            "TransferEncodingDecoder",
            "HeaderCharsetDetector",
            "TextEnrichedDecoder",
            "MIMEParser",
            "EmailMultipartHandler",
            "EmailFormatFlowedHandler",
            "EmailContentParser",
            "ContentCleaner",
            "ContentExtractor",
            "ContentAnalyzer",
            "HTMLEntityDecoder"
        ]
    }
    
    /// Get list of deprecated/duplicate classes to avoid
    public static var deprecatedClasses: [String] {
        return [
            "MultipartTypeHandler",
            "MultipartTypeHandler 2", 
            "FormatFlowedHandler 2"
        ]
    }
    
    /// Check if a class name is recommended for use
    public static func isRecommendedClass(_ className: String) -> Bool {
        return activeClasses.contains(className)
    }
    
    /// Check if a class name should be avoided
    public static func isDeprecatedClass(_ className: String) -> Bool {
        return deprecatedClasses.contains(className)
    }
}