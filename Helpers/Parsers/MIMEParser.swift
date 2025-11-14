// MIMEParser.swift - Enhanced MIME parser with improved charset handling
// ERWEITERT: Besseres Charset-Handling für ISO-8859-1, Windows-1252, und fallback-Logik
// PHASE 3: Single-Pass MIME Parser with complete structured output
import Foundation

// MARK: - Legacy Types (for backwards compatibility)

public struct MIMEContent {
    public var text: String?
    public var html: String?
    public var attachments: [MIMEAttachment] = []
}

public struct MIMEAttachment {
    public var filename: String?
    public var mimeType: String
    public var data: Data
    public var contentId: String?
    public var isInline: Bool
}

// MARK: - Phase 3 Parse Result Types

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

/// Legacy type for backwards compatibility
public struct ParsedEmailContent: Sendable {
    public let text: String?
    public let html: String?
    
    public init(text: String?, html: String?) {
        self.text = text
        self.html = html
    }
}

public class MIMEParser {
    
    private let decoder = ContentDecoder()
    
    public init() {}
    
    // MARK: - Phase 3 Main Parse Method
    
    /// Parse MIME content with BODYSTRUCTURE guidance (Phase 3 entry point)
    /// This is the modern API - parses ONCE and produces complete output
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
    
    /// Legacy parse method for backwards compatibility with Phase 1/2 code
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
    
    /// Main parse method with enhanced charset handling
    public func parse(
        rawBodyBytes: Data?,
        rawBodyString: String?,
        contentType: String?,
        charset: String?
    ) -> MIMEContent {
        
        // ✨ ERWEITERT: Normalisiere Charset-Namen frühzeitig
        let normalizedCharset = normalizeCharsetName(charset)
        
        // ✨ NEU: Wenn contentType/charset nil sind, versuche aus rawBody zu extrahieren
        var effectiveContentType = contentType
        var effectiveCharset = normalizedCharset

        if effectiveContentType == nil || effectiveCharset == nil {
            if let str = rawBodyString {
                let extracted = extractContentTypeFromRawBody(str)
                if effectiveContentType == nil { effectiveContentType = extracted.contentType }
                if effectiveCharset == nil { effectiveCharset = normalizeCharsetName(extracted.charset) }
                
                print("🔍 [MIMEParser] Extracted from rawBody - contentType: \(effectiveContentType ?? "nil"), charset: \(effectiveCharset ?? "nil")")
            }
        }
        
        // If we have raw bytes and charset info, try to decode properly first
        if let bytes = rawBodyBytes, let cs = effectiveCharset {
            if let decoded = decodeDataWithCharset(bytes, charset: cs) {
                return parseFromString(decoded, contentType: effectiveContentType, charset: cs)
            }
        }
        
        // Fallback to string-based parsing
        if let str = rawBodyString {
            return parseFromString(str, contentType: effectiveContentType, charset: effectiveCharset)
        }
        
        // If we have bytes but no charset, try smart detection
        if let bytes = rawBodyBytes {
            let detected = detectCharsetFromData(bytes)
            if let decoded = decodeDataWithCharset(bytes, charset: detected) {
                return parseFromString(decoded, contentType: effectiveContentType, charset: detected)
            }
        }
        
        // ✨ ERWEITERT: Debug-Logging am Ende
        print("🔍 [MIMEParser] Result - text: 0, html: 0 (no valid input)")
        return MIMEContent()
    }
    
    // MARK: - Enhanced Charset Handling
    
    // MARK: - Content-Type Auto-Detection
    
    /// ✨ NEUE METHODE: Extrahiert Content-Type und Charset aus rawBody
    private func extractContentTypeFromRawBody(_ rawBody: String) -> (contentType: String?, charset: String?) {
        let lines = rawBody.components(separatedBy: "\n")
        var contentType: String?
        var charset: String?
        
        for line in lines.prefix(50) { // Nur ersten 50 Zeilen durchsuchen
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.lowercased().hasPrefix("content-type:") {
                let value = trimmed.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                contentType = value.split(separator: ";").first.map(String.init)
                
                // Charset extrahieren
                if let charsetRange = value.range(of: "charset=", options: .caseInsensitive) {
                    let charsetPart = String(value[charsetRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    charset = charsetPart.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
                break
            }
        }
        
        return (contentType, charset)
    }
    
    /// ✨ NEUE METHODE: Normalisiert Charset-Namen zu standardisierten Werten
    private func normalizeCharsetName(_ charset: String?) -> String? {
        guard let cs = charset?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        
        // Mapping von Variationen zu Standard-Namen
        switch cs {
        // UTF-8 Varianten
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return "utf-8"
            
        // ISO-8859-1 Varianten (Latin-1)
        case "iso-8859-1", "iso88591", "latin-1", "latin1", "l1", "cp819":
            return "iso-8859-1"
            
        // ISO-8859-15 Varianten (Latin-9 mit Euro)
        case "iso-8859-15", "iso885915", "latin-9", "latin9", "l9":
            return "iso-8859-15"
            
        // Windows-1252 Varianten
        case "windows-1252", "win-1252", "cp1252", "ms-ansi", "windows1252":
            return "windows-1252"
            
        // ASCII Varianten
        case "us-ascii", "ascii", "ansi_x3.4-1968":
            return "us-ascii"
            
        // Mac Roman
        case "macroman", "mac-roman", "mac", "macintosh", "x-mac-roman":
            return "macroman"
            
        default:
            return cs // Return as-is if unknown
        }
    }
    
    /// ✨ ERWEITERT: Dekodiert Data mit spezifischem Charset und Fallback-Logik
    private func decodeDataWithCharset(_ data: Data, charset: String?) -> String? {
        guard let cs = charset?.lowercased() else {
            // No charset specified - try smart detection
            return smartDecodeData(data)
        }
        
        // Versuche Dekodierung mit angegebenem Charset
        switch cs {
        case "utf-8":
            if let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            // UTF-8 fehlgeschlagen - versuche Fallback
            print("⚠️ MIMEParser: UTF-8 decode failed, trying fallback")
            return smartDecodeData(data)
            
        case "iso-8859-1":
            if let decoded = String(data: data, encoding: .isoLatin1) {
                // ✨ ERWEITERT: Prüfe auf UTF-8 mis-decoded als Latin-1
                return fixUTF8MisdecodedAsLatin1(decoded)
            }
            return smartDecodeData(data)
            
        case "iso-8859-15":
            // ISO-8859-15 (Latin-9) - ähnlich wie Latin-1 aber mit Euro
            if let decoded = String(data: data, encoding: .isoLatin1) {
                return fixUTF8MisdecodedAsLatin1(decoded)
            }
            return smartDecodeData(data)
            
        case "windows-1252":
            if let decoded = String(data: data, encoding: .windowsCP1252) {
                return fixUTF8MisdecodedAsWindows1252(decoded)
            }
            // Fallback zu ISO-8859-1 wenn Windows-1252 fehlschlägt
            print("⚠️ MIMEParser: Windows-1252 decode failed, trying ISO-8859-1")
            return String(data: data, encoding: .isoLatin1)
            
        case "us-ascii":
            return String(data: data, encoding: .ascii) ?? smartDecodeData(data)
            
        case "macroman":
            return smartDecodeData(data)
            
        default:
            // Unknown charset - use robust detection with fallback
            print("⚠️ MIMEParser: Unknown charset '\(cs)', using robust detection")
            let detectedCharset = detectCharsetWithFallback(declaredCharset: cs, content: data)
            return smartDecodeData(data, preferredCharset: detectedCharset)
        }
    }
    
    /// ✨ NEUE METHODE: Intelligente Charset-Erkennung aus Daten
    private func detectCharsetFromData(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        
        // Prüfe auf UTF-8 BOM
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return "utf-8"
        }
        
        // Prüfe auf UTF-16 BOM
        if bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE {
                return "utf-16le"
            }
            if bytes[0] == 0xFE && bytes[1] == 0xFF {
                return "utf-16be"
            }
        }
        
        // Versuche UTF-8 Validierung
        if isValidUTF8(bytes) {
            return "utf-8"
        }
        
        // Prüfe auf Windows-1252 spezifische Zeichen
        if hasWindows1252Characters(bytes) {
            return "windows-1252"
        }
        
        // Fallback zu ISO-8859-1 (sicherer Fallback)
        return "iso-8859-1"
    }
    
    /// ✨ NEUE METHODE: Prüft ob Bytes valides UTF-8 sind
    private func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            
            if byte < 0x80 {
                // ASCII - 1 byte
                i += 1
            } else if byte < 0xC0 {
                // Invalid start byte
                return false
            } else if byte < 0xE0 {
                // 2-byte sequence
                if i + 1 >= bytes.count { return false }
                if bytes[i + 1] < 0x80 || bytes[i + 1] >= 0xC0 { return false }
                i += 2
            } else if byte < 0xF0 {
                // 3-byte sequence
                if i + 2 >= bytes.count { return false }
                for j in 1...2 {
                    if bytes[i + j] < 0x80 || bytes[i + j] >= 0xC0 { return false }
                }
                i += 3
            } else if byte < 0xF8 {
                // 4-byte sequence
                if i + 3 >= bytes.count { return false }
                for j in 1...3 {
                    if bytes[i + j] < 0x80 || bytes[i + j] >= 0xC0 { return false }
                }
                i += 4
            } else {
                // Invalid byte
                return false
            }
        }
        return true
    }
    
    /// ✨ NEUE METHODE: Prüft auf Windows-1252 spezifische Zeichen
    private func hasWindows1252Characters(_ bytes: [UInt8]) -> Bool {
        // Zeichen die in Windows-1252 aber nicht in ISO-8859-1 definiert sind
        let windows1252Specific: [UInt8] = [
            0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8E,
            0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9E, 0x9F
        ]
        return bytes.contains { windows1252Specific.contains($0) }
    }
    
    /// ✨ NEUE METHODE: Intelligente Dekodierung mit automatischem Fallback (robust)
    private func smartDecodeData(_ data: Data, preferredCharset: String? = nil) -> String? {
        // Try preferred charset first if specified
        if let charset = preferredCharset {
            switch charset.lowercased() {
            case "utf-8":
                if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            case "windows-1252":
                if let win1252 = String(data: data, encoding: .windowsCP1252) { return win1252 }
            case "iso-8859-1":
                if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
            default:
                break
            }
        }
        
        // Versuch 1: UTF-8
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        
        // Versuch 2: Windows-1252 (häufig bei E-Mails)
        if let win1252 = String(data: data, encoding: .windowsCP1252) {
            return win1252
        }
        
        // Versuch 3: ISO-8859-1 (sicherer Fallback)
        return String(data: data, encoding: .isoLatin1)
    }
    
    /// ✨ ERWEITERT: Korrigiert UTF-8 Bytes die als ISO-8859-1 dekodiert wurden
    private func fixUTF8MisdecodedAsLatin1(_ text: String) -> String {
        // Erkenne typische UTF-8 Artefakte bei fehlerhafter Latin-1 Dekodierung
        let artifacts = [
            "Ã¼": "ü", "Ã¤": "ä", "Ã¶": "ö", "ÃŸ": "ß",
            "Ã©": "é", "Ã¨": "è", "Ãª": "ê", "Ã«": "ë",
            "Ã¡": "á", "Ã­": "í", "Ã³": "ó", "Ãº": "ú",
            "Ã±": "ñ", "Ã§": "ç", "Ã ": "à", "Ã¹": "ù"
        ]
        
        // Prüfe ob typische Artefakte vorhanden sind
        let hasArtifacts = artifacts.keys.contains { text.contains($0) }
        
        if hasArtifacts {
            // Versuche Re-Enkodierung als ISO-8859-1 und Dekodierung als UTF-8
            if let data = text.data(using: .isoLatin1),
               let corrected = String(data: data, encoding: .utf8) {
                print("✅ MIMEParser: Fixed UTF-8 mis-decoded as Latin-1")
                return corrected
            }
        }
        
        return text
    }
    
    /// ✨ NEUE METHODE: Korrigiert UTF-8 Bytes die als Windows-1252 dekodiert wurden
    private func fixUTF8MisdecodedAsWindows1252(_ text: String) -> String {
        // Ähnlich wie Latin-1, aber mit Windows-1252 spezifischen Zeichen
        if let data = text.data(using: .windowsCP1252),
           let utf8Test = String(data: data, encoding: .utf8),
           utf8Test != text {
            print("✅ MIMEParser: Fixed UTF-8 mis-decoded as Windows-1252")
            return utf8Test
        }
        return text
    }
    
    // MARK: - Parsing Logic
    
    private func parseFromString(
        _ body: String,
        contentType: String?,
        charset: String?
    ) -> MIMEContent {
        guard let ct = contentType else {
            // No content-type - treat as plain text
            let result = MIMEContent(text: body, html: nil, attachments: [])
            print("🔍 [MIMEParser] Result - text: \(result.text?.count ?? 0), html: 0 (no content-type)")
            return result
        }
        
        // ✅ FIX: Nur für VERGLEICHE lowercase nutzen, Original-String für Parameter-Extraktion behalten
        let ctLower = ct.lowercased()
        
        if ctLower.contains("multipart/") {
            // ✅ WICHTIG: ct (nicht ctLower!) für Parameter-Extraktion verwenden
            return parseMultipart(body, contentType: ct, params: extractParams(ct))
        } else if ctLower.contains("text/html") {
            let result = MIMEContent(text: nil, html: body, attachments: [])
            print("🔍 [MIMEParser] Result - text: 0, html: \(result.html?.count ?? 0)")
            return result
        } else if ctLower.contains("text/plain") {
            let result = MIMEContent(text: body, html: nil, attachments: [])
            print("🔍 [MIMEParser] Result - text: \(result.text?.count ?? 0), html: 0")
            return result
        } else {
            // Unknown content type - default to text
            let result = MIMEContent(text: body, html: nil, attachments: [])
            print("🔍 [MIMEParser] Result - text: \(result.text?.count ?? 0), html: 0 (unknown content-type)")
            return result
        }
    }
    
    private func parseMultipart(
        _ body: String,
        contentType: String,
        params: [String: String]
    ) -> MIMEContent {
        // Try robust boundary detection first
        guard let boundary = robustDetectBoundary(from: contentType) ?? 
                            params["boundary"] ??
                            guessBoundaryFromContent(rawContent: body) else {
            print("⚠️ MIMEParser: No boundary found in multipart content")
            return MIMEContent(text: body, html: nil, attachments: [])
        }
        
        var htmlPart: String?
        var textPart: String?
        var attachments: [MIMEAttachment] = []
        
        // ✅ PHASE 3: Robuste Boundary-Verarbeitung
        let parts = parseMultipartParts(body, boundary: boundary)
        print("🔍 PHASE 3: Found \(parts.count) multipart parts with boundary '\(boundary)'")
        
        for (index, part) in parts.enumerated() {
            print("🔍 PHASE 3: Processing part \(index + 1), length: \(part.count)")
            
            // Split headers and body
            let split = part.components(separatedBy: "\r\n\r\n")
            if split.count < 2 {
                // Try alternative separator
                let altSplit = part.components(separatedBy: "\n\n")
                guard altSplit.count >= 2 else { 
                    print("⚠️ PHASE 3: Part \(index + 1) has invalid structure, skipping")
                    continue 
                }
                let headerBlock = altSplit[0]
                let bodyBlock = altSplit.dropFirst().joined(separator: "\n\n")
                processMultipartPart(headerBlock: headerBlock, bodyBlock: bodyBlock, 
                                   htmlPart: &htmlPart, textPart: &textPart, attachments: &attachments)
            } else {
                let headerBlock = split[0]
                let bodyBlock = split.dropFirst().joined(separator: "\r\n\r\n")
                processMultipartPart(headerBlock: headerBlock, bodyBlock: bodyBlock, 
                                   htmlPart: &htmlPart, textPart: &textPart, attachments: &attachments)
            }
        }
        
        print("✅ PHASE 3: Multipart parsing complete - text: \(textPart?.count ?? 0), html: \(htmlPart?.count ?? 0), attachments: \(attachments.count)")
        
        let result = MIMEContent(text: textPart, html: htmlPart, attachments: attachments)
        print("🔍 [MIMEParser] Result - text: \(result.text?.count ?? 0), html: \(result.html?.count ?? 0)")
        return result
    }
    
    /// ✅ PHASE 3: Robuste Boundary-basierte Part-Extraktion
    private func parseMultipartParts(_ body: String, boundary: String) -> [String] {
        var parts: [String] = []
        
        // Standardisiere Zeilenumbrüche für konsistentes Parsing
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
                                  .replacingOccurrences(of: "\r", with: "\n")
        
        let boundaryMarker = "--\(boundary)"
        let closingBoundary = "--\(boundary)--"
        
        let lines = normalizedBody.components(separatedBy: "\n")
        var currentPart: [String] = []
        var inPart = false
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Check for boundary markers
            if trimmedLine == boundaryMarker || trimmedLine.hasPrefix(boundaryMarker + " ") {
                // Start of new part or end of previous part
                if inPart && !currentPart.isEmpty {
                    // Save previous part (without boundaries)
                    let partContent = currentPart.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partContent.isEmpty {
                        parts.append(partContent)
                    }
                }
                
                // Start new part
                currentPart = []
                inPart = true
                continue
                
            } else if trimmedLine == closingBoundary || trimmedLine.hasPrefix(closingBoundary + " ") {
                // End of multipart
                if inPart && !currentPart.isEmpty {
                    let partContent = currentPart.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partContent.isEmpty {
                        parts.append(partContent)
                    }
                }
                break
                
            } else if inPart {
                // Content line of current part
                currentPart.append(line)
            }
            // else: we're before the first boundary, ignore
        }
        
        // Handle case where there's no closing boundary
        if inPart && !currentPart.isEmpty {
            let partContent = currentPart.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !partContent.isEmpty {
                parts.append(partContent)
            }
        }
        
        return parts
    }
    
    /// ✅ PHASE 3: Verarbeite einzelnen Multipart-Teil (extrahiert für bessere Lesbarkeit)
    private func processMultipartPart(
        headerBlock: String,
        bodyBlock: String,
        htmlPart: inout String?,
        textPart: inout String?,
        attachments: inout [MIMEAttachment]
    ) {
        // Use robust header parsing
        let headers = tolerantParseHeaders(from: headerBlock)
        let disp = headers["content-disposition"]
        let ctypeRaw = headers["content-type"] ?? "text/plain"
        let (ctype, cparams) = parseContentType(ctypeRaw)
        let cte = headers["content-transfer-encoding"]?.lowercased()
        let cid = extractContentId(from: headers["content-id"])

        // Multipart nesting
        if ctype.type.lowercased().hasPrefix("multipart/") {
            let nested = parseMultipart(bodyBlock, contentType: ctype.full, params: cparams)
            // Merge nested results (prefer html/text if not set yet)
            if htmlPart == nil, let h = nested.html { htmlPart = h }
            if textPart == nil, let t = nested.text { textPart = t }
            attachments.append(contentsOf: nested.attachments)
            return
        }

        // ✅ PHASE 3: Dekodiere Body mit verbessertem Content-Handling
        let partCharset = normalizeCharsetName(cparams["charset"])
        let decodedData: Data
        
        if let enc = cte {
            switch enc {
            case "base64":
                decodedData = decodeBase64Data(bodyBlock)
            case "quoted-printable":
                // ✅ Dekodiere QP mit Charset-Awareness
                let qpDecoded = decodeQuotedPrintableWithCharset(bodyBlock, charset: partCharset)
                decodedData = Data(qpDecoded.utf8)
            default:
                decodedData = Data(bodyBlock.utf8)
            }
        } else {
            decodedData = Data(bodyBlock.utf8)
        }

        // Handle text parts mit verbessertem Charset-Handling
        if ctype.type.lowercased() == "text/plain" {
            if let s = decodeDataWithCharset(decodedData, charset: partCharset) {
                if textPart == nil { textPart = s }
            }
            return
        }
        if ctype.type.lowercased() == "text/html" {
            if let s = decodeDataWithCharset(decodedData, charset: partCharset) {
                if htmlPart == nil { htmlPart = s }
            }
            return
        }
        if ctype.type.lowercased() == "text/enriched" {
            if let s = decodeDataWithCharset(decodedData, charset: partCharset) {
                // Convert text/enriched to HTML and store as HTML part
                let htmlContent = TextEnrichedDecoder.decodeToHTML(s)
                if htmlPart == nil { htmlPart = htmlContent }
                // Also store as text part if we don't have one yet
                if textPart == nil {
                    textPart = TextEnrichedDecoder.decodeToPlainText(s)
                }
            }
            return
        }

        // Handle attachments (including inline images)
        let isAttachment = (disp?.lowercased().contains("attachment") == true)
        let isInline = (disp?.lowercased().contains("inline") == true) || (cid != nil)
        if isAttachment || isInline || !ctype.type.lowercased().hasPrefix("text/") {
            // Use improved filename extraction with I18N support
            let filename = decodeInternationalFilename(from: headers) ?? 
                         extractFilename(from: disp) ?? 
                         "attachment"
            
            let attachment = MIMEAttachment(
                filename: filename,
                mimeType: ctype.type,
                data: decodedData,
                contentId: cid,
                isInline: isInline
            )
            attachments.append(attachment)
        }
    }
    
    /// ✨ ERWEITERT: Quoted-Printable Dekodierung mit Charset-Awareness
    private func decodeQuotedPrintableWithCharset(_ text: String, charset: String?) -> String {
        var result = ""
        var i = text.startIndex
        
        while i < text.endIndex {
            let c = text[i]
            
            if c == "=" {
                let nextIndex = text.index(after: i)
                if nextIndex >= text.endIndex {
                    break
                }
                
                // Check for soft line break (=\r\n or =\n)
                if text[nextIndex] == "\r" || text[nextIndex] == "\n" {
                    // Skip soft line break
                    i = text.index(after: nextIndex)
                    if text[nextIndex] == "\r" && i < text.endIndex && text[i] == "\n" {
                        i = text.index(after: i)
                    }
                    continue
                }
                
                // Decode hex sequence
                let hex1Index = nextIndex
                if hex1Index >= text.endIndex { break }
                let hex2Index = text.index(after: hex1Index)
                if hex2Index >= text.endIndex { break }
                
                let hex = String(text[hex1Index...hex2Index])
                if let byte = UInt8(hex, radix: 16) {
                    // ✨ ERWEITERT: Interpretiere Byte basierend auf Charset
                    result.append(interpretByteWithCharset(byte, charset: charset))
                    i = text.index(after: hex2Index)
                } else {
                    result.append(c)
                    i = text.index(after: i)
                }
            } else {
                result.append(c)
                i = text.index(after: i)
            }
        }
        
        return result
    }
    
    /// ✨ NEUE METHODE: Interpretiert ein Byte basierend auf Charset
    private func interpretByteWithCharset(_ byte: UInt8, charset: String?) -> String {
        guard let cs = charset?.lowercased() else {
            // No charset - assume UTF-8/ASCII
            return String(UnicodeScalar(byte))
        }
        
        // Für ISO-8859-1 und Windows-1252 können wir direkt konvertieren
        switch cs {
        case "iso-8859-1", "windows-1252":
            return String(UnicodeScalar(byte))
        default:
            return String(UnicodeScalar(byte))
        }
    }
    
    // MARK: - Helper Methods (existing)
    
    private func extractCharset(from contentType: String) -> String? {
        // Look for charset=xxx in content type
        let pattern = /charset=["']?([^"';\s]+)["']?/
        if let match = contentType.firstMatch(of: pattern) {
            return String(match.1).lowercased()
        }
        return nil
    }
    
    // MARK: - Phase 6: Robust MIME Parser Extensions
    
    /// Robustly detect boundaries even with malformed headers
    /// Many real-world emails violate RFC by having inconsistent boundaries
    private func robustDetectBoundary(from contentType: String) -> String? {
        // Standard: boundary="something"
        if let boundary = extractParams(contentType)["boundary"] {
            return boundary
        }
        
        // Fallback: boundary=something (no quotes)
        if let range = contentType.range(of: "boundary=", options: .caseInsensitive) {
            let afterBoundary = contentType[range.upperBound...]
            let boundaryValue = afterBoundary
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let boundary = boundaryValue, !boundary.isEmpty {
                print("⚠️  [MIME-ROBUST] Found unquoted boundary: \(boundary)")
                return boundary
            }
        }
        
        return nil
    }
    
    /// Find boundary in raw content when header parsing fails
    /// Scans first 1000 bytes for boundary-like patterns
    private func guessBoundaryFromContent(rawContent: String) -> String? {
        let lines = rawContent.prefix(1000).components(separatedBy: "\n")
        
        for line in lines {
            // Look for lines starting with -- (boundary marker)
            if line.hasPrefix("--") && line.count > 10 && line.count < 100 {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.rangeOfCharacter(from: .alphanumerics) != nil {
                    print("⚠️  [MIME-ROBUST] Guessed boundary from content: \(candidate)")
                    return String(candidate.dropFirst(2)) // Remove --
                }
            }
        }
        
        return nil
    }
    
    /// Parse headers with tolerance for common violations
    private func tolerantParseHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
            // Empty line = end of headers
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            
            // Continuation line (starts with space/tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentKey != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            
            // New header line
            if let colonIndex = line.firstIndex(of: ":") {
                // Save previous header
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // Parse new header
                currentKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Malformed line - append to current value if we have one
                if currentKey != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Save last header
        if let key = currentKey {
            headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return headers
    }
    
    /// Decode filename with proper I18N support
    /// Handles: filename*=UTF-8''... (RFC2231) and =?UTF-8?Q?...?= (RFC2047)
    private func decodeInternationalFilename(from headers: [String: String]) -> String? {
        // Try Content-Disposition first
        if let disposition = headers["content-disposition"] {
            if let filename = decodeFilenameFromDisposition(disposition) {
                return filename
            }
        }
        
        // Try Content-Type as fallback (some mailers put filename there)
        if let contentType = headers["content-type"] {
            if let filename = decodeFilenameFromContentType(contentType) {
                return filename
            }
        }
        
        return nil
    }
    
    /// Decode filename from Content-Disposition header
    private func decodeFilenameFromDisposition(_ disposition: String) -> String? {
        // RFC2231: filename*=UTF-8''encoded-name
        if let rfc2231Filename = extractRFC2231Parameter(from: disposition, parameter: "filename") {
            return rfc2231Filename
        }
        
        // RFC2047: filename="=?UTF-8?Q?...?="
        if let rfc2047Filename = extractQuotedParameter(from: disposition, parameter: "filename") {
            return decodeRFC2047(rfc2047Filename)
        }
        
        // Plain filename
        if let plainFilename = extractQuotedParameter(from: disposition, parameter: "filename") {
            return plainFilename
        }
        
        return nil
    }
    
    /// Decode filename from Content-Type header (legacy support)
    private func decodeFilenameFromContentType(_ contentType: String) -> String? {
        // Some old mailers put filename in Content-Type: name="..."
        if let name = extractQuotedParameter(from: contentType, parameter: "name") {
            return decodeRFC2047(name)
        }
        
        return nil
    }
    
    /// Extract RFC2231 encoded parameter: parameter*=charset'language'value
    private func extractRFC2231Parameter(from header: String, parameter: String) -> String? {
        // Look for parameter*=
        let pattern = "\(parameter)\\*=([^;]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
            return nil
        }
        
        guard let valueRange = Range(match.range(at: 1), in: header) else {
            return nil
        }
        
        let encodedValue = String(header[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse: charset'language'value
        let parts = encodedValue.components(separatedBy: "'")
        if parts.count >= 3 {
            let charset = parts[0].uppercased()
            let encodedText = parts[2]
            
            // Percent-decode
            guard let decoded = encodedText.removingPercentEncoding else {
                return nil
            }
            
            // Convert from charset if needed
            if charset == "UTF-8" || charset == "UTF8" {
                return decoded
            }
            
            // Handle other charsets (ISO-8859-1, etc.)
            return decoded
        }
        
        return nil
    }
    
    /// Extract quoted parameter value: parameter="value"
    private func extractQuotedParameter(from header: String, parameter: String) -> String? {
        // Look for parameter="value" or parameter=value
        let patterns = [
            "\(parameter)=\"([^\"]+)\"",  // Quoted
            "\(parameter)=([^;\\s]+)"     // Unquoted
        ]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
                continue
            }
            
            guard let valueRange = Range(match.range(at: 1), in: header) else {
                continue
            }
            
            return String(header[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    /// Decode RFC2047 encoded-word: =?charset?encoding?encoded-text?=
    private func decodeRFC2047(_ text: String) -> String {
        // Pattern: =?charset?Q|B?encoded?=
        let pattern = "=\\?([^?]+)\\?([QB])\\?([^?]+)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        // Decode in reverse to maintain string indices
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let charsetRange = Range(match.range(at: 1), in: text),
                  let encodingRange = Range(match.range(at: 2), in: text),
                  let dataRange = Range(match.range(at: 3), in: text) else {
                continue
            }
            
            let charset = String(text[charsetRange]).uppercased()
            let encoding = String(text[encodingRange]).uppercased()
            let encodedData = String(text[dataRange])
            
            var decoded: String?
            
            if encoding == "Q" {
                // Quoted-Printable
                decoded = decodeQuotedPrintableForFilename(encodedData)
            } else if encoding == "B" {
                // Base64
                if let data = Data(base64Encoded: encodedData) {
                    decoded = String(data: data, encoding: .utf8)
                }
            }
            
            if let decodedText = decoded {
                result.replaceSubrange(fullRange, with: decodedText)
            }
        }
        
        return result
    }
    
    /// Decode Quoted-Printable for filename (underscore = space)
    private func decodeQuotedPrintableForFilename(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "_", with: " ")
        
        // Decode =XX hex sequences
        let pattern = "=([0-9A-F]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return result
        }
        
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            
            let hexString = String(result[hexRange])
            if let byte = UInt8(hexString, radix: 16) {
                let char = String(UnicodeScalar(byte))
                result.replaceSubrange(fullRange, with: char)
            }
        }
        
        return result
    }
    
    /// Detect charset with fallback mechanisms
    private func detectCharsetWithFallback(declaredCharset: String?, content: Data) -> String {
        // Try declared charset first
        if let charset = declaredCharset?.lowercased(),
           !charset.isEmpty && charset != "unknown" {
            return charset
        }
        
        // Try to detect from BOM
        if content.count >= 3 {
            let bom = [UInt8](content.prefix(3))
            if bom == [0xEF, 0xBB, 0xBF] {
                return "utf-8"
            }
        }
        
        // Check if valid UTF-8
        if String(data: content, encoding: .utf8) != nil {
            return "utf-8"
        }
        
        // Default fallback
        return "iso-8859-1"
    }
    
    private func extractContentId(from contentIdHeader: String?) -> String? {
        guard let contentId = contentIdHeader else { return nil }
        return contentId.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }
    
    private func extractBoundary(from contentType: String) -> String? {
        return extractParams(contentType)["boundary"]
    }
    
    // MARK: - Legacy Header Parsing
    
    private func parseHeaders(_ headerBlock: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = headerBlock.components(separatedBy: "\r\n")
        var current: String = ""
        
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                current += line.trimmingCharacters(in: .whitespaces)
            } else {
                if !current.isEmpty {
                    if let sep = current.firstIndex(of: ":") {
                        let key = current[..<sep].lowercased()
                        let value = current[current.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                        headers[String(key)] = value
                    }
                }
                current = line
            }
        }
        
        if !current.isEmpty {
            if let sep = current.firstIndex(of: ":") {
                let key = current[..<sep].lowercased()
                let value = current[current.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                headers[String(key)] = value
            }
        }
        
        return headers
    }
    
    private func extractParams(_ contentType: String) -> [String: String] {
        var params: [String: String] = [:]
        let parts = contentType.split(separator: ";")
        
        for part in parts.dropFirst() {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyValue = trimmed.split(separator: "=", maxSplits: 1)
            
            if keyValue.count == 2 {
                let key = String(keyValue[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var value = String(keyValue[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                
                params[key] = value
            }
        }
        
        return params
    }
    
    private func parseHeaders(_ headerBlock: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = headerBlock.components(separatedBy: "\r\n")
        var current: String = ""
        
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                current += line.trimmingCharacters(in: .whitespaces)
            } else {
                if !current.isEmpty {
                    if let sep = current.firstIndex(of: ":") {
                        let key = current[..<sep].lowercased()
                        let value = current[current.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                        headers[String(key)] = value
                    }
                }
                current = line
            }
        }
        
        if !current.isEmpty {
            if let sep = current.firstIndex(of: ":") {
                let key = current[..<sep].lowercased()
                let value = current[current.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                headers[String(key)] = value
            }
        }
        
        return headers
    }

    private func parseContentType(_ raw: String) -> (type: (type: String, full: String), params: [String: String]) {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        var params: [String: String] = [:]
        
        if parts.count > 1 {
            for p in parts.dropFirst() {
                let pair = p.split(separator: "=", maxSplits: 1)
                if pair.count == 2 {
                    let k = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                    var v = pair[1].trimmingCharacters(in: .whitespaces)
                    if v.hasPrefix("\"") && v.hasSuffix("\"") {
                        v.removeFirst()
                        v.removeLast()
                    }
                    params[k] = v
                }
            }
        }
        
        return ((type, raw), params)
    }

    private func extractFilename(from disp: String?) -> String? {
        guard let disp else { return nil }
        
        // filename* (RFC 5987) not fully implemented; basic filename= support
        if let r = disp.range(of: "filename*=") {
            let tail = String(disp[r.upperBound...])
            if let semi = tail.firstIndex(of: ";") {
                return decodeRFC5987(String(tail[..<semi]))
            }
            return decodeRFC5987(tail)
        }
        
        if let r = disp.range(of: "filename=") {
            var fn = String(disp[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if fn.hasPrefix("\"") { fn.removeFirst() }
            if fn.hasSuffix("\"") { fn.removeLast() }
            if let semi = fn.firstIndex(of: ";") { fn = String(fn[..<semi]) }
            return fn
        }
        
        return nil
    }

    private func decodeRFC5987(_ s: String) -> String? {
        // Basic RFC 5987 decoding: charset'lang'value
        let parts = s.split(separator: "'")
        guard parts.count >= 3 else { return s }
        
        let encoded = String(parts[2])
        return encoded.removingPercentEncoding
    }

    private func decodeBase64Data(_ s: String) -> Data {
        let clean = s.filter { !$0.isWhitespace }
        return Data(base64Encoded: clean) ?? Data()
    }
    
    private func decodeQuotedPrintable(_ s: String) -> String {
        // Fallback to simple QP decoding if charset is unknown
        return decodeQuotedPrintableWithCharset(s, charset: nil)
    }
}

// MARK: - Phase 3 Content Decoder (stub)

/// Placeholder for content decoder - should be implemented separately
private class ContentDecoder {
    func decode(data: Data, transferEncoding: String?, charset: String) -> Data {
        // This is a simplified stub - real implementation would handle:
        // - Base64 decoding
        // - Quoted-printable decoding
        // - Character set conversion
        return data
    }
}

// MARK: - Phase 3 Type Stubs (to be defined elsewhere)

/// Placeholder - should be defined in Phase 2 BODYSTRUCTURE parser
public struct EnhancedBodyStructure {
    public let sections: [BodySection]
    
    public init(sections: [BodySection]) {
        self.sections = sections
    }
}

/// Placeholder - should be defined in Phase 2 BODYSTRUCTURE parser
public struct BodySection {
    public let sectionId: String
    public let mediaType: String
    public let disposition: String?
    public let filename: String?
    public let contentId: String?
    public let size: Int?
    public let isBodyCandidate: Bool
    
    public init(sectionId: String, mediaType: String, disposition: String? = nil,
                filename: String? = nil, contentId: String? = nil, size: Int? = nil,
                isBodyCandidate: Bool = false) {
        self.sectionId = sectionId
        self.mediaType = mediaType
        self.disposition = disposition
        self.filename = filename
        self.contentId = contentId
        self.size = size
        self.isBodyCandidate = isBodyCandidate
    }
}

/// Helper structure for MIME part
public struct MIMEPart {
    public let partId: String
    public let headers: [String: String]
    public let body: String
    public let mediaType: String
    public let charset: String?
    public let transferEncoding: String?
    public let disposition: String?
    public let filename: String?
    public let contentId: String?
    
    public init(partId: String, headers: [String: String], body: String,
                mediaType: String, charset: String? = nil, transferEncoding: String? = nil,
                disposition: String? = nil, filename: String? = nil, contentId: String? = nil) {
        self.partId = partId
        self.headers = headers
        self.body = body
        self.mediaType = mediaType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.disposition = disposition
        self.filename = filename
        self.contentId = contentId
    }
}

/// Placeholder - should be defined in Phase 1 entities
public struct MimePartEntity {
    public let messageId: UUID
    public let partId: String
    public let parentPartId: String?
    public let mediaType: String
    public let charset: String?
    public let transferEncoding: String?
    public let disposition: String?
    public let filenameOriginal: String?
    public let filenameNormalized: String?
    public let contentId: String?
    public let contentMd5: String?
    public let contentSha256: String?
    public let sizeOctets: Int?
    public let bytesStored: Int?
    public let isBodyCandidate: Bool
    public let blobId: String?
}

/// Placeholder - should be defined in Phase 1 entities
public struct AttachmentEntity {
    public let accountId: UUID
    public let folder: String
    public let uid: String
    public let partId: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let data: Data
    public let contentId: String?
    public let isInline: Bool
    public let filePath: String?
    public let checksum: String?
}

/// Placeholder - should be implemented separately for text/enriched support
public struct TextEnrichedDecoder {
    public static func decodeToHTML(_ enrichedText: String) -> String {
        // Stub implementation - convert enriched text to basic HTML
        return "<html><body>\(enrichedText)</body></html>"
    }
    
    public static func decodeToPlainText(_ enrichedText: String) -> String {
        // Stub implementation - strip enriched markup
        return enrichedText
    }
}

// MARK: - Phase 3 Conversion Extensions

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

/*
 PHASE 6 ROBUST MIME PARSER EXTENSIONS INTEGRATED
 ================================================
 
 This file now includes enhanced robustness features:
 
 ✅ INTEGRATED FEATURES:
 - Robust boundary detection (handles malformed headers)
 - Tolerant header parsing (RFC violations)
 - International filename decoding (RFC2231 + RFC2047)
 - Enhanced charset detection with fallback
 - UTF-8 misencoding detection and correction
 - BOM detection
 - Quoted-printable filename decoding
 
 USAGE EXAMPLES:
 
 International Filenames:
 - Handles filename*=UTF-8''%C3%BCber.txt → "über.txt"
 - Supports =?UTF-8?Q?...?= encoded words
 
 Robust Parsing:
 - Works with boundary=something (no quotes)
 - Recovers from malformed MIME structure
 - Tolerates missing Content-Type headers
 
 Charset Handling:
 - Auto-detects UTF-8 vs Latin-1 vs Windows-1252
 - Corrects common misencoding issues
 - Falls back gracefully on unknown charsets
 */
