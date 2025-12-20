// AILO_APP/Helpers/Parsers/MIMEParser_Phase3.swift
// PHASE 3: Single-Pass MIME Parser
// Parses MIME content ONCE and produces complete structured output

import Foundation

// MARK: - Parse Result

/// Complete result from MIME parsing (single pass)
public struct MIMEParseResult: Sendable {
    public let parts: [ParsedMIMEPart]
    public let bestBodyCandidate: BodyCandidate?
    public let attachments: [ParsedAttachment]
    public let inlineReferences: [InlineReference]
    
    public init(parts: [ParsedMIMEPart], bestBodyCandidate: BodyCandidate?,
                attachments: [ParsedAttachment], inlineReferences: [InlineReference]) {
        self.parts = parts
        self.bestBodyCandidate = bestBodyCandidate
        self.attachments = attachments
        self.inlineReferences = inlineReferences
    }
}

/// Parsed MIME part with all metadata
public struct ParsedMIMEPart: Sendable, Identifiable {
    public let id: String                    // Part ID (e.g. "1.2")
    public let parentId: String?             // Parent part ID
    public let mediaType: String             // Full type (e.g. "text/html")
    public let charset: String?              // Character set
    public let transferEncoding: String?     // Transfer encoding
    public let disposition: String?          // inline/attachment
    public let filename: String?             // Original filename
    public let contentId: String?            // For cid: references
    public let size: Int?                    // Size in bytes
    public let content: Data?                // Decoded content (if fetched)
    
    public init(id: String, parentId: String? = nil, mediaType: String,
                charset: String? = nil, transferEncoding: String? = nil,
                disposition: String? = nil, filename: String? = nil,
                contentId: String? = nil, size: Int? = nil, content: Data? = nil) {
        self.id = id
        self.parentId = parentId
        self.mediaType = mediaType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.disposition = disposition
        self.filename = filename
        self.contentId = contentId
        self.size = size
        self.content = content
    }
}

/// Best body content choice (HTML preferred over text)
public struct BodyCandidate: Sendable {
    public let partId: String
    public let contentType: BodyContentType
    public let charset: String
    public let content: String
    
    public init(partId: String, contentType: BodyContentType, 
                charset: String, content: String) {
        self.partId = partId
        self.contentType = contentType
        self.charset = charset
        self.content = content
    }
}

public enum BodyContentType: String, Sendable {
    case html = "text/html"
    case plain = "text/plain"
}

/// Parsed attachment ready for storage
public struct ParsedAttachment: Sendable, Identifiable {
    public let id: String                    // Part ID
    public let filename: String
    public let mediaType: String
    public let disposition: String           // inline/attachment
    public let contentId: String?            // For cid:
    public let size: Int
    public let content: Data
    
    public init(id: String, filename: String, mediaType: String,
                disposition: String, contentId: String? = nil,
                size: Int, content: Data) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.disposition = disposition
        self.contentId = contentId
        self.size = size
        self.content = content
    }
}

/// Inline reference (for cid: rewriting)
public struct InlineReference: Sendable, Identifiable {
    public let id: String { contentId }
    public let contentId: String             // CID value
    public let partId: String                // Which part contains this
    public let mediaType: String             // image/png, etc.
    
    public init(contentId: String, partId: String, mediaType: String) {
        self.contentId = contentId
        self.partId = partId
        self.mediaType = mediaType
    }
}

// MARK: - Enhanced MIME Parser

/// Phase 3: Single-pass MIME parser with complete output
public class EnhancedMIMEParser {
    
    private let decoder = ContentDecoder()
    
    // MARK: - Main Parse Method
    
    /// Parse MIME content with BODYSTRUCTURE guidance
    /// This is the Phase 3 entry point - parses ONCE and produces complete output
    /// - Parameters:
    ///   - structure: Pre-parsed BODYSTRUCTURE (from Phase 2)
    ///   - sectionContents: Fetched section contents (from Phase 2)
    ///   - defaultCharset: Fallback charset
    /// - Returns: Complete parse result
    public func parseWithStructure(
        structure: EnhancedBodyStructure,
        sectionContents: [String: Data],
        defaultCharset: String = "utf-8"
    ) -> MIMEParseResult {
        
        print("🔍 [MIMEParser Phase3] Starting single-pass parse")
        print("   - Sections in structure: \(structure.sections.count)")
        print("   - Section contents available: \(sectionContents.count)")
        
        var parts: [ParsedMIMEPart] = []
        var attachments: [ParsedAttachment] = []
        var inlineRefs: [InlineReference] = []
        var bodyCandidates: [(priority: Int, candidate: BodyCandidate)] = []
        
        // Process each section
        for section in structure.sections {
            guard let data = sectionContents[section.sectionId] else {
                print("⚠️ [MIMEParser Phase3] No content for section \(section.sectionId)")
                continue
            }
            
            // Decode content
            let charset = extractCharset(from: section.mediaType) ?? defaultCharset
            let transferEncoding = "quoted-printable" // TODO: Extract from MIME headers
            
            let decodedData = decoder.decode(
                data: data,
                transferEncoding: transferEncoding,
                charset: charset
            )
            
            // Create parsed part
            let part = ParsedMIMEPart(
                id: section.sectionId,
                parentId: nil, // TODO: Track from structure
                mediaType: section.mediaType,
                charset: charset,
                transferEncoding: transferEncoding,
                disposition: section.disposition,
                filename: section.filename,
                contentId: section.contentId,
                size: section.size,
                content: decodedData
            )
            parts.append(part)
            
            // Handle body candidates
            if section.isBodyCandidate {
                if let bodyContent = String(data: decodedData, encoding: .utf8) {
                    let contentType: BodyContentType = section.mediaType.contains("html") ? .html : .plain
                    let priority = contentType == .html ? 1 : 2 // HTML preferred
                    
                    let candidate = BodyCandidate(
                        partId: section.sectionId,
                        contentType: contentType,
                        charset: charset,
                        content: bodyContent
                    )
                    bodyCandidates.append((priority, candidate))
                }
            }
            
            // Handle attachments
            if section.disposition == "attachment" || 
               (section.disposition == "inline" && !section.mediaType.hasPrefix("text/")) {
                let attachment = ParsedAttachment(
                    id: section.sectionId,
                    filename: section.filename ?? "attachment",
                    mediaType: section.mediaType,
                    disposition: section.disposition ?? "attachment",
                    contentId: section.contentId,
                    size: decodedData.count,
                    content: decodedData
                )
                attachments.append(attachment)
            }
            
            // Track inline references (for cid: rewriting)
            if let cid = section.contentId, section.disposition == "inline" {
                let ref = InlineReference(
                    contentId: cid,
                    partId: section.sectionId,
                    mediaType: section.mediaType
                )
                inlineRefs.append(ref)
            }
        }
        
        // Select best body candidate (HTML preferred)
        let bestBody = bodyCandidates.sorted { $0.priority < $1.priority }.first?.candidate
        
        print("✅ [MIMEParser Phase3] Parse complete")
        print("   - Parts: \(parts.count)")
        print("   - Body: \(bestBody?.contentType.rawValue ?? "none")")
        print("   - Attachments: \(attachments.count)")
        print("   - Inline refs: \(inlineRefs.count)")
        
        return MIMEParseResult(
            parts: parts,
            bestBodyCandidate: bestBody,
            attachments: attachments,
            inlineReferences: inlineRefs
        )
    }
    
    /// Legacy parse method (for backwards compatibility)
    /// Use parseWithStructure() for new code
    public func parse(rawBodyBytes: Data?, rawBodyString: String?,
                     contentType: String, charset: String) -> ParsedEmailContent {
        // This is a simplified fallback for old code
        // Real implementation would need full MIME parsing
        
        let body = rawBodyString ?? String(data: rawBodyBytes ?? Data(), encoding: .utf8) ?? ""
        
        if contentType.contains("html") {
            return ParsedEmailContent(text: nil, html: body)
        } else {
            return ParsedEmailContent(text: body, html: nil)
        }
    }
    
    // MARK: - Helper Methods
    
    private func extractCharset(from contentType: String) -> String? {
        // Look for charset=xxx in content type
        let pattern = /charset=["']?([^"';\s]+)["']?/
        if let match = contentType.firstMatch(of: pattern) {
            return String(match.1).lowercased()
        }
        return nil
    }
}

// MARK: - Legacy Type (for backwards compatibility)

public struct ParsedEmailContent: Sendable {
    public let text: String?
    public let html: String?
    
    public init(text: String?, html: String?) {
        self.text = text
        self.html = html
    }
}

// MARK: - Conversion Extensions

extension MIMEParseResult {
    
    /// Convert to Phase 1 MIME part entities for storage
    public func toMimePartEntities(messageId: UUID) -> [MimePartEntity] {
        return parts.map { part in
            MimePartEntity(
                messageId: messageId,
                partId: part.id,
                parentPartId: part.parentId,
                mediaType: part.mediaType,
                charset: part.charset,
                transferEncoding: part.transferEncoding,
                disposition: part.disposition,
                filenameOriginal: part.filename,
                filenameNormalized: part.filename?.sanitizedFilename(),
                contentId: part.contentId,
                contentMd5: nil,
                contentSha256: nil, // Will be set when storing blob
                sizeOctets: part.size,
                bytesStored: part.content?.count,
                isBodyCandidate: part.mediaType.hasPrefix("text/"),
                blobId: nil // Will be set when storing blob
            )
        }
    }
    
    /// Convert to Phase 1 attachment entities for storage
    public func toAttachmentEntities(accountId: UUID, folder: String, uid: String) -> [AttachmentEntity] {
        return attachments.map { attachment in
            AttachmentEntity(
                accountId: accountId,
                folder: folder,
                uid: uid,
                partId: attachment.id,
                filename: attachment.filename,
                mimeType: attachment.mediaType,
                sizeBytes: attachment.size,
                data: attachment.content,
                contentId: attachment.contentId,
                isInline: attachment.disposition == "inline",
                filePath: nil, // Will be set by storage layer
                checksum: nil  // Will be calculated by BlobStore
            )
        }
    }
}

// MARK: - String Extension

private extension String {
    func sanitizedFilename() -> String {
        let basename = (self as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let sanitized = basename.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
        return sanitized.isEmpty ? "attachment" : sanitized
    }
}
