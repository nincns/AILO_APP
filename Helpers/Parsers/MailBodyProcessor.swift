// MailBodyProcessor.swift - KOMPLETTE eigenständige Lösung für Mail-Dekodierung
// Keine externen Abhängigkeiten außer Foundation - KORRIGIERTE VERSION
// Verarbeitet RAW → Text/HTML vollständig in dieser Datei
import Foundation

/// Zentrale, eigenständige Helper-Klasse für RAW → HTML/Text Dekodierung
/// WICHTIG: Diese Klasse ändert NIE die RAW-Daten in der DB!
public class MailBodyProcessor {
    
    // MARK: - Public API
    
    /// Prüft ob Body noch MIME-Kodierung enthält
    public static func needsProcessing(_ body: String?) -> Bool {
        guard let body = body, !body.isEmpty else {
            print("🔍 [needsProcessing] TRUE - Body is nil or empty")
            return true
        }
        
        let lines = body.components(separatedBy: .newlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // KRITISCH: Prüfe auf End-Boundary (definitivstes Zeichen für RAW-Format)
        // End-Boundary Pattern: --BOUNDARY-- (mit trailing --)
        let lastLines = lines.suffix(10)
        for line in lastLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") && trimmed.hasSuffix("--") && trimmed.count > 4 {
                let withoutDashes = trimmed.dropFirst(2).dropLast(2)
                if withoutDashes.count > 5 {
                    print("🔍 [needsProcessing] TRUE - End-boundary found: \(trimmed.prefix(40))...")
                    return true
                }
            }
        }
        
        // Prüfe auf isolierte MIME-Header am Anfang (ohne nachfolgenden Content)
        let firstLines = lines.prefix(20)
        var mimeHeaderCount = 0
        var hasContentAfterHeaders = false
        
        for (index, line) in firstLines.enumerated() {
            let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
            
            if lower.hasPrefix("content-type:") ||
               lower.hasPrefix("content-transfer-encoding:") ||
               lower.hasPrefix("mime-version:") {
                mimeHeaderCount += 1
            } else if !lower.isEmpty && mimeHeaderCount > 0 {
                // Nicht-leere Zeile nach MIME-Headern gefunden
                // Prüfe ob es echter Content ist (nicht nur weitere Header)
                if !lower.contains(":") || lower.starts(with: "<") {
                    hasContentAfterHeaders = true
                    break
                }
            }
        }
        
        // Wenn MIME-Header gefunden wurden UND danach echter Content kommt
        // → Wahrscheinlich bereits verarbeitet (HTML kann Content-Type Meta-Tags haben)
        if mimeHeaderCount > 0 && hasContentAfterHeaders {
            print("🔍 [needsProcessing] FALSE - MIME headers found but followed by content (likely processed)")
            return false
        }
        
        // Wenn MIME-Header gefunden wurden OHNE Content danach
        // → Noch nicht verarbeitet
        if mimeHeaderCount >= 2 {
            print("🔍 [needsProcessing] TRUE - Multiple MIME headers without content")
            return true
        }
        
        // Prüfe ob Content wie bereits verarbeitetes HTML aussieht
        if trimmedBody.lowercased().hasPrefix("<html") ||
           trimmedBody.lowercased().hasPrefix("<!doctype") ||
           trimmedBody.lowercased().hasPrefix("<div") ||
           trimmedBody.lowercased().hasPrefix("<p") {
            print("🔍 [needsProcessing] FALSE - Content appears to be processed HTML")
            return false
        }
        
        // Prüfe ob Content wie normaler Text aussieht (keine MIME-Strukturen)
        let hasBoundaryMarkers = trimmedBody.contains("--") &&
                                 (trimmedBody.contains("Content-Type:") ||
                                  trimmedBody.contains("boundary="))
        
        if !hasBoundaryMarkers {
            print("🔍 [needsProcessing] FALSE - No boundary markers, appears processed")
            return false
        }
        
        print("🔍 [needsProcessing] TRUE - Default case, requires processing")
        return true
    }
    
    /// Dekodiert rawBody zu text/html - KOMPLETT eigenständig mit allen FIXES
    public static func processRawBody(_ rawBody: String) -> (text: String?, html: String?) {
        print("🔄 [MailBodyProcessor] Processing rawBody (\(rawBody.count) chars)...")
        
        // FIX 1: Normalisiere Zeilenendings ZUERST
        let normalizedBody = normalizeLineEndings(rawBody)
        
        // Schritt 1: Extrahiere Content-Type Header
        guard let contentTypeHeader = extractContentTypeHeader(normalizedBody) else {
            print("   ⚠️ No Content-Type found, treating as plain text")
            return (cleanText(normalizedBody), nil)
        }
        
        print("   📋 Content-Type: \(contentTypeHeader)")
        
        // Schritt 2: Prüfe ob multipart
        if contentTypeHeader.lowercased().contains("multipart") {
            return processMultipart(normalizedBody, contentType: contentTypeHeader)
        } else {
            // Single part mail
            return processSinglePart(normalizedBody, contentType: contentTypeHeader)
        }
    }
    
    // MARK: - FIX 1: Line Ending Normalization
    
    /// Normalisiert alle Zeilenendings zu \n
    private static func normalizeLineEndings(_ content: String) -> String {
        return content.replacingOccurrences(of: "\r\n", with: "\n")
                     .replacingOccurrences(of: "\r", with: "\n")
    }
    
    // MARK: - Multipart Processing
    
    private static func processMultipart(_ rawBody: String, contentType: String) -> (text: String?, html: String?) {
        print("   🔀 Processing multipart mail...")
        
        // Extrahiere boundary
        guard let boundary = extractBoundary(contentType) else {
            print("   ❌ No boundary found in multipart!")
            return (cleanText(rawBody), nil)
        }
        
        print("   🏷️  Boundary: \(boundary)")
        
        // Teile Body an Boundaries
        let parts = splitByBoundary(rawBody, boundary: boundary)
        print("   📦 Found \(parts.count) parts")
        
        var textContent: String? = nil
        var htmlContent: String? = nil
        
        // Verarbeite jeden Part
        for (index, part) in parts.enumerated() {
            print("   📝 Processing part \(index + 1)...")
            
            // FIX 3: Trimme Part BEVOR Header/Body-Trennung
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else {
                print("      ⚠️ Part is empty after trimming")
                continue
            }
            
            guard let (headers, body) = splitHeadersAndBody(trimmedPart) else {
                print("      ⚠️ Could not split headers/body")
                continue
            }
            
            let partContentType = extractPartContentType(headers) ?? "text/plain"
            let transferEncoding = extractTransferEncoding(headers) ?? "7bit"
            
            print("      - Content-Type: \(partContentType)")
            print("      - Transfer-Encoding: \(transferEncoding)")
            print("      - Body length: \(body.count)")
            
            // Dekodiere Body
            let decodedBody = decodeBody(body, transferEncoding: transferEncoding)
            
            // Speichere je nach Content-Type
            if partContentType.lowercased().contains("text/html") {
                htmlContent = decodedBody
                print("      ✅ HTML part decoded (\(decodedBody.count) chars)")
            } else if partContentType.lowercased().contains("text/plain") {
                textContent = decodedBody
                print("      ✅ Text part decoded (\(decodedBody.count) chars)")
            }
        }
        
        print("   ✅ Multipart processing complete")
        print("      - Text: \(textContent?.count ?? 0) chars")
        print("      - HTML: \(htmlContent?.count ?? 0) chars")
        
        return (textContent, htmlContent)
    }
    
    // MARK: - Single Part Processing
    
    private static func processSinglePart(_ rawBody: String, contentType: String) -> (text: String?, html: String?) {
        print("   📄 Processing single part mail...")
        
        // FIX 3: Trimme Body BEVOR Header/Body-Trennung
        let trimmedBody = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let (headers, body) = splitHeadersAndBody(trimmedBody) else {
            print("   ⚠️ Could not split headers/body, treating as text")
            return (cleanText(trimmedBody), nil)
        }
        
        let transferEncoding = extractTransferEncoding(headers) ?? "7bit"
        let decodedBody = decodeBody(body, transferEncoding: transferEncoding)
        
        if contentType.lowercased().contains("text/html") {
            print("   ✅ Single HTML part decoded (\(decodedBody.count) chars)")
            return (nil, decodedBody)
        } else {
            print("   ✅ Single text part decoded (\(decodedBody.count) chars)")
            return (decodedBody, nil)
        }
    }
    
    // MARK: - Header Extraction
    
    private static func extractContentTypeHeader(_ rawBody: String) -> String? {
        let lines = rawBody.components(separatedBy: .newlines)
        var contentType = ""
        var inContentType = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Start of Content-Type header
            if trimmed.lowercased().hasPrefix("content-type:") {
                contentType = String(trimmed.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
                inContentType = true
                
                // Check if multi-line
                if !trimmed.hasSuffix(";") && !trimmed.hasSuffix(",") {
                    break
                }
                continue
            }
            
            // Continuation line (starts with whitespace)
            if inContentType && (line.hasPrefix(" ") || line.hasPrefix("\t")) {
                contentType += " " + trimmed
                
                if !trimmed.hasSuffix(";") && !trimmed.hasSuffix(",") {
                    break
                }
                continue
            } else if inContentType {
                // New header started
                break
            }
        }
        
        return contentType.isEmpty ? nil : contentType
    }
    
    private static func extractBoundary(_ contentType: String) -> String? {
        // Pattern: boundary="something" or boundary=something
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        
        let afterBoundary = contentType[range.upperBound...]
        let parts = afterBoundary.split(separator: ";", maxSplits: 1)
        guard let boundaryValue = parts.first else {
            return nil
        }
        
        var boundary = String(boundaryValue).trimmingCharacters(in: .whitespaces)
        
        // Remove quotes if present
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        
        return boundary
    }
    
    private static func splitByBoundary(_ content: String, boundary: String) -> [String] {
        var parts: [String] = []
        
        // Content ist bereits normalisiert durch normalizeLineEndings()
        let boundaryMarker = "--\(boundary)"
        let closingBoundary = "--\(boundary)--"
        
        let lines = content.components(separatedBy: "\n")
        var currentPart: [String] = []
        var inPart = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check for boundary
            if trimmed == boundaryMarker || trimmed.hasPrefix(boundaryMarker + " ") {
                // Save previous part
                if inPart && !currentPart.isEmpty {
                    let partContent = currentPart.joined(separator: "\n")
                    if !partContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parts.append(partContent)
                    }
                }
                
                // Start new part
                currentPart = []
                inPart = true
                continue
            }
            
            // Check for closing boundary
            if trimmed == closingBoundary || trimmed.hasPrefix(closingBoundary + " ") {
                // Save last part
                if inPart && !currentPart.isEmpty {
                    let partContent = currentPart.joined(separator: "\n")
                    if !partContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        parts.append(partContent)
                    }
                }
                break
            }
            
            // Collect part content
            if inPart {
                currentPart.append(line)
            }
        }
        
        return parts
    }
    
    private static func splitHeadersAndBody(_ content: String) -> (headers: String, body: String)? {
        let lines = content.components(separatedBy: "\n")
        var headerLines: [String] = []
        var bodyStartIndex = 0
        
        for (index, line) in lines.enumerated() {
            // 1. Klassischer Trenner: Leere Zeile
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                bodyStartIndex = index + 1
                break
            }
            
            // 2. Header-Fortsetzung (beginnt mit Space/Tab)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !headerLines.isEmpty {
                // An vorherige Zeile anhängen (Header-Folding)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                headerLines[headerLines.count - 1] += " " + trimmed
                continue
            }
            
            // 3. Echte Header-Zeile (enthält ":")
            if line.contains(":") {
                headerLines.append(line)
                continue
            }
            
            // 4. FALLBACK: Erste Nicht-Headerzeile = Body beginnt hier
            // (für Apple Mail ohne Leerzeile zwischen Headers und Body)
            bodyStartIndex = index
            break
        }
        
        // Body-Zeilen ab bodyStartIndex sammeln
        let bodyLines = Array(lines[bodyStartIndex...])
        
        let headers = headerLines.joined(separator: "\n")
        let body = bodyLines.joined(separator: "\n")
        
        return (headers: headers, body: body)
    }
    
    private static func extractPartContentType(_ headers: String) -> String? {
        let lines = headers.components(separatedBy: .newlines)
        for line in lines {
            if line.lowercased().hasPrefix("content-type:") {
                let value = String(line.dropFirst("content-type:".count))
                    .trimmingCharacters(in: .whitespaces)
                // Get only the type part (before semicolon)
                return value.split(separator: ";").first.map(String.init)
            }
        }
        return nil
    }
    
    private static func extractTransferEncoding(_ headers: String) -> String? {
        let lines = headers.components(separatedBy: .newlines)
        for line in lines {
            if line.lowercased().hasPrefix("content-transfer-encoding:") {
                return String(line.dropFirst("content-transfer-encoding:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }
        }
        return nil
    }
    
    // MARK: - Body Decoding
    
    private static func decodeBody(_ body: String, transferEncoding: String) -> String {
        switch transferEncoding.lowercased() {
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        case "base64":
            return decodeBase64(body)
        default:
            return body
        }
    }
    
    /// Quoted-Printable Decoder - vollständig eigenständig mit Soft Wrap Support
    private static func decodeQuotedPrintable(_ text: String) -> String {
        // SCHRITT 1: Entferne alle Soft Line Breaks (=\n) ZUERST
        let withoutSoftWraps = text.replacingOccurrences(of: "=\n", with: "")
        
        // SCHRITT 2: Dekodiere QP-Hexwerte (=XX)
        var result = ""
        var i = withoutSoftWraps.startIndex
        
        while i < withoutSoftWraps.endIndex {
            let c = withoutSoftWraps[i]
            
            if c == "=" {
                // Dekodiere Hex-Sequenz =XX
                let nextIndex = withoutSoftWraps.index(after: i)
                guard nextIndex < withoutSoftWraps.endIndex else {
                    // = am Ende, ignorieren
                    break
                }
                
                let hex1Index = nextIndex
                guard hex1Index < withoutSoftWraps.endIndex else { break }
                
                let hex2Index = withoutSoftWraps.index(after: hex1Index)
                guard hex2Index < withoutSoftWraps.endIndex else { break }
                
                let hexString = String(withoutSoftWraps[hex1Index...hex2Index])
                
                if let byte = UInt8(hexString, radix: 16) {
                    // Convert byte to character (UInt8 always creates valid UnicodeScalar)
                    let scalar = UnicodeScalar(byte)
                    result.append(Character(scalar))
                    i = withoutSoftWraps.index(after: hex2Index)
                } else {
                    // Invalid hex - keep original
                    result.append(c)
                    i = withoutSoftWraps.index(after: i)
                }
            } else {
                result.append(c)
                i = withoutSoftWraps.index(after: i)
            }
        }
        
        return result
    }
    
    /// Base64 Decoder - vollständig eigenständig
    private static func decodeBase64(_ text: String) -> String {
        // Remove whitespace
        let cleaned = text.filter { !$0.isWhitespace }
        
        guard let data = Data(base64Encoded: cleaned),
              let decoded = String(data: data, encoding: .utf8) else {
            return text
        }
        
        return decoded
    }
    
    // MARK: - Text Cleanup
    
    private static func cleanText(_ text: String) -> String {
        var content = text
        
        // Remove email headers at start
        content = removeEmailHeaders(content)
        
        // Normalize line breaks
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")
        
        // Remove excessive whitespace
        content = content.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func removeEmailHeaders(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var contentStart = 0
        var inHeaders = false
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check for email header patterns
            if isEmailHeaderLine(trimmed) {
                inHeaders = true
            } else if trimmed.isEmpty && inHeaders {
                // Empty line after headers = start of content
                contentStart = index + 1
                break
            } else if inHeaders && !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                // Non-header line after headers = start of content
                contentStart = index
                break
            }
        }
        
        if contentStart > 0 && contentStart < lines.count {
            return Array(lines[contentStart...]).joined(separator: "\n")
        }
        
        return content
    }
    
    private static func isEmailHeaderLine(_ line: String) -> Bool {
        let headerPrefixes = [
            "Return-Path:", "Received:", "From:", "To:", "Subject:",
            "Date:", "Message-ID:", "Message-Id:", "MIME-Version:",
            "Content-Type:", "Content-Transfer-Encoding:",
            "X-", "Delivered-To:"
        ]
        
        return headerPrefixes.contains { line.hasPrefix($0) }
    }
}
