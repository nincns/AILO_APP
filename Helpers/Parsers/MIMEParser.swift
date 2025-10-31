// AILO_APP/Configuration/Services/Mail/MIMEParser.swift
// MIME parser for message bodies: multipart boundaries, base64/quoted-printable decoding, charset normalization.
// Produces structured output: text, html, attachments (incl. inline via Content-ID).
// Designed to be pragmatic and resilient; does not implement full RFC 2045/2047 header decoding.

import Foundation

// MARK: - Model

public struct MimeAttachment {
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
}

public struct MimeContent {
    public let text: String?
    public let html: String?
    public let attachments: [MimeAttachment]

    public init(text: String? = nil, html: String? = nil, attachments: [MimeAttachment] = []) {
        self.text = text
        self.html = html
        self.attachments = attachments
    }
}

// MARK: - Parser

public struct MIMEParser {
    public init() {}

    /// Entry point for body parsing. Accepts raw body data or string and content headers.
    public func parse(rawBodyBytes: Data?, rawBodyString: String?, contentType: String?, charset: String?) -> MimeContent {
        // Resolve raw string, keep bytes for potential binary decodes
        let rawString: String
        if let s = rawBodyString {
            rawString = s
        } else if let d = rawBodyBytes, let s = String(data: d, encoding: .utf8) {
            rawString = s
        } else {
            return MimeContent()
        }

        // Determine content type and charset (may be overridden by part headers later)
        let (topType, topParams) = parseContentType(contentType ?? "text/plain")
        let normalizedCharset = topParams["charset"] ?? normalizeCharset(charset)

        if topType.type.lowercased().hasPrefix("multipart/") {
            return parseMultipart(rawString, contentType: topType.full, params: topParams)
        }

        if topType.type.lowercased() == "text/html" {
            let normalized = convertCharset(rawString, from: normalizedCharset)
            return MimeContent(text: stripHTMLPreservingParagraphs(normalized), html: normalized)
        }

        if topType.type.lowercased() == "text/enriched" {
            let normalized = convertCharset(rawString, from: normalizedCharset)
            let htmlContent = TextEnrichedDecoder.decodeToHTML(normalized)
            let plainContent = TextEnrichedDecoder.decodeToPlainText(normalized)
            return MimeContent(text: plainContent, html: htmlContent)
        }

        // Default plain text
        let normalized = convertCharset(rawString, from: normalizedCharset)
        return MimeContent(text: normalized)
    }

    // MARK: Multipart

    private func parseMultipart(_ body: String, contentType: String, params: [String: String]) -> MimeContent {
        guard let boundary = params["boundary"], !boundary.isEmpty else {
            return MimeContent(text: body)
        }
        // Split parts by boundary markers per RFC 2046
        let open = "--" + boundary
        let close = open + "--"
        var textPart: String? = nil
        var htmlPart: String? = nil
        var attachments: [MimeAttachment] = []

        // Extract blocks between boundaries
        let lines = body.components(separatedBy: "\r\n")
        var buffer: [String] = []
        var inPart = false
        func flushPart() {
            guard !buffer.isEmpty else { return }
            let joined = buffer.joined(separator: "\r\n")
            buffer.removeAll(keepingCapacity: true)
            // Parse headers/body split
            let split = joined.components(separatedBy: "\r\n\r\n")
            guard split.count >= 1 else { return }
            let headerBlock = split.first ?? ""
            let bodyBlock = split.dropFirst().joined(separator: "\r\n\r\n")
            let headers = parseHeaders(headerBlock)
            let disp = headers["content-disposition"]
            let ctypeRaw = headers["content-type"] ?? "text/plain"
            let (ctype, cparams) = parseContentType(ctypeRaw)
            let cte = headers["content-transfer-encoding"]?.lowercased()
            let cid = headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))

            // Multipart nesting
            if ctype.type.lowercased().hasPrefix("multipart/") {
                let nested = parseMultipart(bodyBlock, contentType: ctype.full, params: cparams)
                // Merge nested results (prefer html/text if not set yet)
                if htmlPart == nil, let h = nested.html { htmlPart = h }
                if textPart == nil, let t = nested.text { textPart = t }
                attachments.append(contentsOf: nested.attachments)
                return
            }

            // Decode body according to CTE and charset
            let charset = cparams["charset"]?.lowercased()
            let decodedData: Data
            if let enc = cte {
                switch enc {
                case "base64":
                    decodedData = decodeBase64Data(bodyBlock)
                case "quoted-printable":
                    decodedData = Data(decodeQuotedPrintable(bodyBlock).utf8)
                default:
                    decodedData = Data(bodyBlock.utf8)
                }
            } else {
                decodedData = Data(bodyBlock.utf8)
            }

            // Handle text parts
            if ctype.type.lowercased() == "text/plain" {
                if let s = stringFromData(decodedData, charset: charset) {
                    if textPart == nil { textPart = s }
                }
                return
            }
            if ctype.type.lowercased() == "text/html" {
                if let s = stringFromData(decodedData, charset: charset) {
                    if htmlPart == nil { htmlPart = s }
                }
                return
            }
            if ctype.type.lowercased() == "text/enriched" {
                if let s = stringFromData(decodedData, charset: charset) {
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
                let filename = extractFilename(from: disp) ?? cparams["name"] ?? (cid ?? "attachment.dat")
                let mime = ctype.type
                let att = MimeAttachment(filename: filename, mimeType: mime, data: decodedData, contentId: cid, isInline: isInline)
                attachments.append(att)
                return
            }
        }

        for line in lines {
            if line == open {
                // Start of a new part
                if inPart { flushPart() }
                inPart = true
                buffer.removeAll(keepingCapacity: true)
                continue
            } else if line == close {
                // Final boundary – flush and break
                flushPart()
                inPart = false
                break
            }
            if inPart { buffer.append(line) }
        }
        // Flush trailing part if any
        flushPart()

        // If only HTML is present, produce text via HTML stripping
        if textPart == nil, let html = htmlPart {
            textPart = stripHTMLPreservingParagraphs(html)
        }
        return MimeContent(text: textPart, html: htmlPart, attachments: attachments)
    }

    // MARK: Decoding helpers

    private func decodeBase64Data(_ s: String) -> Data {
        // Remove CR/LF and whitespace per RFC 2045 section 6.8
        let cleaned = s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: cleaned) ?? Data()
    }

    public func decodeBase64(_ s: String) -> String {
        let data = decodeBase64Data(s)
        return String(data: data, encoding: .utf8) ?? s
    }

    public func decodeQuotedPrintable(_ s: String) -> String {
        var out = ""
        // Preserve soft line breaks ("=") across lines
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            var softBreak = false
            if line.hasSuffix("=") { softBreak = true; line.removeLast() }
            out += decodeQPFragment(line)
            if !softBreak && idx < lines.count - 1 { out += "\n" }
        }
        return out
    }

    private func decodeQPFragment(_ s: String) -> String {
        var result = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=", i + 2 < chars.count {
                let hexStr = String(chars[(i+1)...(i+2)])
                if let byte = UInt8(hexStr, radix: 16) { result.append(Character(UnicodeScalar(byte))); i += 3; continue }
            }
            result.append(c)
            i += 1
        }
        return result
    }

    // MARK: Charset helpers

    private func normalizeCharset(_ charset: String?) -> String? {
        guard let c = charset?.lowercased() else { return nil }
        switch c {
        case "utf8": return "utf-8"
        case "latin1": return "iso-8859-1"
        case "windows-1252": return "windows-1252"
        default: return c
        }
    }

    private func stringFromData(_ data: Data, charset: String?) -> String? {
        let cs = (charset?.lowercased()) ?? "utf-8"
        
        switch cs {
        case "utf-8":
            return String(data: data, encoding: .utf8)
        case "iso-8859-1", "latin1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252":
            return String(data: data, encoding: .windowsCP1252)
        default:
            // Try UTF-8 first, then fallback to ISO-8859-1
            if let utf8String = String(data: data, encoding: .utf8) {
                return utf8String
            }
            // If UTF-8 fails, try ISO-8859-1 as fallback
            return String(data: data, encoding: .isoLatin1)
        }
    }

    private func convertCharset(_ s: String, from charset: String?) -> String {
        guard let cs = charset?.lowercased(), !cs.isEmpty else { return s }
        
        // If charset is UTF-8, return as-is
        if cs == "utf-8" { return s }
        
        // For other charsets, we need to handle the conversion properly
        // The issue is that the string 's' is already a Swift String (UTF-8 internally)
        // but may have been incorrectly decoded from the original bytes
        // We should avoid double-conversion which causes the ÃÂ issue
        
        // First, try to detect if this looks like already correctly decoded UTF-8
        // by checking for typical UTF-8 decode artifacts
        if looksLikeUTF8DecodedAsLatin1(s) {
            // This looks like UTF-8 bytes that were incorrectly decoded as ISO-8859-1
            // Try to fix by re-encoding as ISO-8859-1 and decoding as UTF-8
            if let data = s.data(using: .isoLatin1), 
               let corrected = String(data: data, encoding: .utf8) {
                return corrected
            }
        }
        
        return s
    }
    
    /// Detects if a string looks like UTF-8 content that was incorrectly decoded as ISO-8859-1
    private func looksLikeUTF8DecodedAsLatin1(_ s: String) -> Bool {
        // Common UTF-8 sequences when decoded as ISO-8859-1:
        // ü = C3 BC → Ã¼
        // ä = C3 A4 → Ã¤  
        // ö = C3 B6 → Ã¶
        // ß = C3 9F → ÃŸ
        // é = C3 A9 → Ã©
        // è = C3 A8 → Ã¨
        // ê = C3 AA → Ãª
        let utf8Artifacts = ["Ã¼", "Ã¤", "Ã¶", "ÃŸ", "Ã©", "Ã¨", "Ãª", "Ã¡", "Ã­", "Ã³", "Ãº", "Ã±"]
        return utf8Artifacts.contains { s.contains($0) }
    }

    // MARK: Header parsing

    /// Parse raw headers into a lowercase-key dictionary, handling folded lines (RFC 5322).
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
                        headers[key] = value
                    }
                }
                current = line
            }
        }
        if !current.isEmpty {
            if let sep = current.firstIndex(of: ":") {
                let key = current[..<sep].lowercased()
                let value = current[current.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
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
                    if v.hasPrefix("\"") && v.hasSuffix("\"") { v.removeFirst(); v.removeLast() }
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
            // Attempt to decode RFC 5987: filename*=utf-8''encoded
            let tail = String(disp[r.upperBound...])
            if let semi = tail.firstIndex(of: ";") { return decodeRFC5987(String(tail[..<semi])) }
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
        // Format: charset''percent-encoded
        let comps = s.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard comps.count == 3 else { return nil }
        let enc = comps[0].lowercased()
        let value = String(comps[2])
        let decoded = value.removingPercentEncoding ?? value
        if enc == "utf-8" { return decoded }
        return decoded
    }

    // MARK: HTML helpers

    public func stripHTMLPreservingParagraphs(_ html: String) -> String {
        var txt = html
        // Normalize common breaks
        txt = txt.replacingOccurrences(of: "<(?i)p>", with: "\n", options: .regularExpression)
        txt = txt.replacingOccurrences(of: "<(?i)br/?>", with: "\n", options: .regularExpression)
        // Strip remaining tags
        txt = txt.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode a minimal set of entities
        txt = txt.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return txt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
