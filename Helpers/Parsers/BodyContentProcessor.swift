// BodyContentProcessor.swift
// Zentrale Klasse für Body-Content-Aufbereitung zur Anzeige
import Foundation

/// Prozessiert bereits dekodierten E-Mail-Body-Content für optimale Anzeige
///
/// Diese Klasse übernimmt die finale Aufbereitung von bereits dekodiertem Content:
/// - Dekodiert Quoted-Printable Encoding
/// - Dekodiert HTML-Entities
/// - Entfernt technische E-Mail-Header aus Body
/// - Filtert HTML-Meta-Tags und DOCTYPE
/// - Normalisiert Sonderzeichen
/// - Unterscheidet Plain-Text vs HTML
public class BodyContentProcessor {
    
    // MARK: - Public API
    
    /// Bereitet HTML-Content für WebView-Anzeige auf
    /// - Parameter html: Bereits dekodierter HTML-String
    /// - Returns: Bereinigter HTML-Content
    /// 
    /// ✅ PHASE 3: Reduzierte Filterung da MIME-Parser jetzt korrekt arbeitet
    public static func cleanHTMLForDisplay(_ html: String) -> String {
        var content = html
        
        // ✅ Schritt 0: KRITISCH - Quoted-Printable Decoding ZUERST!
        content = decodeQuotedPrintableIfNeeded(content)
        
        // ✅ Schritt 0.5: Entferne MIME-Header am Anfang (charset=, boundary=, etc.)
        content = removeMIMEHeadersFromStart(content)
        
        // Schritt 1: Entferne E-Mail-Header aus Body (falls vorhanden)
        content = removeEmailHeaders(content)
        
        // Schritt 2: Entferne/Normalisiere HTML-Meta-Tags
        content = cleanHTMLMetaTags(content)
        
        // ✅ PHASE 3: Leichtere MIME-Boundary-Filterung (MIME-Parser sollte das jetzt richtig machen)
        content = removeStragglerMIMEBoundaries(content)
        
        // ✅ Schritt 4: Decode HTML-Entities
        content = HTMLEntityDecoder.decodeForHTML(content)
        
        // Schritt 5: Normalisiere Sonderzeichen (Legacy, für Sonderfälle)
        content = normalizeSonderzeichen(content)
        
        // Schritt 6: Sichere minimale HTML-Struktur
        content = ensureMinimalHTMLStructure(content)
        
        return content
    }
    
    /// Bereitet Plain-Text-Content für TextView-Anzeige auf
    /// - Parameter text: Bereits dekodierter Plain-Text-String
    /// - Returns: Bereinigter Plain-Text-Content
    public static func cleanPlainTextForDisplay(_ text: String) -> String {
        var content = text
        
        // ✅ Schritt 0: KRITISCH - Quoted-Printable Decoding ZUERST!
        content = decodeQuotedPrintableIfNeeded(content)
        
        // Schritt 1: Entferne E-Mail-Header aus Body
        content = removeEmailHeaders(content)
        
        // Schritt 2: Normalisiere Zeilenumbrüche
        content = normalizeLineBreaks(content)
        
        // ✅ Schritt 3: Decode HTML-Entities für Plain-Text
        content = HTMLEntityDecoder.decodeForPlainText(content)
        
        // Schritt 4: Normalisiere Sonderzeichen (Legacy)
        content = normalizeSonderzeichen(content)
        
        // Schritt 5: Entferne übermäßige Leerzeilen
        content = removeExcessiveWhitespace(content)
        
        // Schritt 6: Entferne einzelne Sonderzeichen am Ende
        content = removeTrailingOrphans(content)
        
        return content
    }
    
    /// Entscheidet welcher Content-Typ bevorzugt wird und liefert finalen Display-Content
    /// - Parameters:
    ///   - html: HTML-Content (optional, bereits durch MIME-Parsing verarbeitet)
    ///   - text: Plain-Text-Content (optional, bereits durch MIME-Parsing verarbeitet)
    /// - Returns: Tuple mit finalem Content und isHTML-Flag
    /// 
    /// ✅ PHASE 2: Optimiert für bereits verarbeitete Daten aus bodyEntity
    public static func selectDisplayContent(html: String?, text: String?) -> (content: String, isHTML: Bool) {
        // Debug-Info für Performance-Monitoring
        let htmlLength = html?.count ?? 0
        let textLength = text?.count ?? 0
        
        // Priorität 1: HTML-Content (bereits verarbeitet)
        if let htmlContent = html, !htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // ✅ PHASE 2: Minimale Nachbearbeitung für bereits verarbeitete HTML-Daten
            let cleaned = finalizeHTMLForDisplay(htmlContent)
            print("✅ PHASE 2: selectDisplayContent - HTML finalized (\(htmlLength) → \(cleaned.count) chars)")
            return (content: cleaned, isHTML: true)
        }
        
        // Priorität 2: Plain-Text (bereits verarbeitet)
        if let textContent = text, !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // ✅ PHASE 2: Minimale Nachbearbeitung für bereits verarbeitete Text-Daten
            let cleaned = finalizePlainTextForDisplay(textContent)
            print("✅ PHASE 2: selectDisplayContent - Text finalized (\(textLength) → \(cleaned.count) chars)")
            return (content: cleaned, isHTML: false)
        }
        
        // Kein Content
        print("⚠️ PHASE 2: selectDisplayContent - No content available (html: \(htmlLength), text: \(textLength))")
        return (content: "", isHTML: false)
    }
    
    /// Erkennt ob Content HTML ist (für bereits dekodierten Content)
    /// - Parameter content: Der zu prüfende Content
    /// - Returns: true wenn HTML erkannt wurde
    public static func isHTMLContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Prüfe auf typische HTML-Marker
        let htmlMarkers = [
            "<html", "<HTML",
            "<!DOCTYPE", "<!doctype",
            "<head>", "<HEAD>",
            "<body", "<BODY",
            "<div", "<DIV",
            "<p>", "<P>",
            "<br", "<BR",
            "<table", "<TABLE"
        ]
        
        for marker in htmlMarkers {
            if trimmed.contains(marker) {
                return true
            }
        }
        
        // Zusätzlich: Wenn mehr als 3 HTML-Tags vorhanden
        let tagPattern = "<[^>]+>"
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let matches = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            if matches.count >= 3 {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - PHASE 2: Optimierte Finalize-Methoden für bereits verarbeitete Daten
    
    /// Finale Bereinigung für bereits verarbeitetes HTML (minimaler Overhead)
    /// - Parameter html: Bereits durch MIME-Parsing und cleanHTMLForDisplay verarbeitetes HTML
    /// - Returns: Final bereinigter HTML-Content für Anzeige
    private static func finalizeHTMLForDisplay(_ html: String) -> String {
        var content = html
        
        // Nur noch finale kosmetische Korrekturen
        // Schritt 1: Sichere minimale HTML-Struktur (falls noch nicht vorhanden)
        content = ensureMinimalHTMLStructure(content)
        
        // Schritt 2: Letzte Cleanup-Phase für Anzeige
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return content
    }
    
    /// Finale Bereinigung für bereits verarbeiteten Plain-Text (minimaler Overhead)
    /// - Parameter text: Bereits durch MIME-Parsing und cleanPlainTextForDisplay verarbeiteter Text
    /// - Returns: Final bereinigter Plain-Text-Content für Anzeige
    private static func finalizePlainTextForDisplay(_ text: String) -> String {
        var content = text
        
        // Nur noch finale kosmetische Korrekturen
        // Schritt 1: Finale Whitespace-Bereinigung
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Schritt 2: Stelle sicher dass nicht komplett leer
        if content.isEmpty {
            return "(Kein Textinhalt verfügbar)"
        }
        
        return content
    }
    
    // MARK: - Transfer Encoding Decoding
    
    /// Dekodiert Quoted-Printable encoding falls vorhanden
    /// - Parameter content: Der zu dekodierende Content
    /// - Returns: Dekodierter Content
    private static func decodeQuotedPrintableIfNeeded(_ content: String) -> String {
        // Prüfe ob Content Quoted-Printable encoded ist
        // Typische Muster: =XX (hex) oder =\n (soft line break)
        let hasQuotedPrintable = content.contains("=3D") ||
                                 content.contains("=C3=") ||
                                 content.range(of: "=[0-9A-F]{2}", options: .regularExpression) != nil
        
        guard hasQuotedPrintable else {
            return content
        }
        
        print("🔄 BodyContentProcessor: Quoted-Printable detected, decoding...")
        
        // Nutze QuotedPrintableDecoder (bereits vorhanden im Projekt)
        let decoded = QuotedPrintableDecoder.decode(content, charset: "utf-8")
        
        print("✅ BodyContentProcessor: Decoded \(content.count) → \(decoded.count) chars")
        
        return decoded
    }
    
    // MARK: - Private Helper Methods
    
    /// Entfernt technische E-Mail-Header aus Body-Content
    /// - Parameter content: Der zu bereinigende Content
    /// - Returns: Content ohne technische Header
    public static func removeEmailHeaders(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        var inHeaderSection = false
        var headerEndIndex = 0
        var cleanedLines: [String] = []
        
        // Phase 1: Erkenne und entferne Header-Section am Anfang
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Typische E-Mail-Header erkennen
            if trimmed.isEmpty && index > 0 {
                // Leere Zeile könnte Header-Ende markieren
                if inHeaderSection {
                    headerEndIndex = index + 1
                    break
                }
            } else if isEmailHeaderLine(trimmed) {
                inHeaderSection = true
            } else if inHeaderSection && !trimmed.isEmpty && !isHeaderContinuation(trimmed) {
                // Nicht-Header-Zeile gefunden - Header-Section beendet
                headerEndIndex = index
                break
            }
        }
        
        // Entferne Header-Zeilen vom Anfang
        if headerEndIndex > 0 && headerEndIndex < lines.count {
            lines.removeFirst(headerEndIndex)
        }
        
        // Phase 2: Entferne einzelne technische Header-Zeilen aus dem Body
        var skipMode = false
        var headerSectionEnded = headerEndIndex > 0
        
        let headerPatterns = [
            "Content-Type:", "Content-Transfer-Encoding:", "Content-Disposition:",
            "MIME-Version:", "X-", "Date:", "From:", "To:", "Subject:", "Message-ID:",
            "Return-Path:", "Received:", "Authentication-Results:", "DKIM-Signature:"
        ]
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Wenn leere Zeile, dann sind wir definitiv nach den Headern
            if trimmedLine.isEmpty {
                headerSectionEnded = true
                cleanedLines.append(line)
                skipMode = false
                continue
            }
            
            // If we're past the header section, include all lines
            if headerSectionEnded {
                cleanedLines.append(line)
                continue
            }
            
            // Check if line starts with a technical header
            let isTechnicalHeader = headerPatterns.contains { pattern in
                trimmedLine.hasPrefix(pattern)
            }
            
            // Check if line is a continuation of previous header (starts with whitespace)
            let isContinuation = line.hasPrefix(" ") || line.hasPrefix("\t")
            
            if isTechnicalHeader {
                skipMode = true
                continue
            } else if isContinuation && skipMode {
                // Skip continuation lines of technical headers
                continue
            } else {
                skipMode = false
                // Only include non-empty lines or if we're clearly past headers
                if !trimmedLine.isEmpty || headerSectionEnded {
                    cleanedLines.append(line)
                }
            }
        }
        
        return cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Prüft ob eine Zeile ein E-Mail-Header ist
    private static func isEmailHeaderLine(_ line: String) -> Bool {
        let headerPatterns = [
            "Content-Type:", "Content-Transfer-Encoding:", "Content-Disposition:",
            "MIME-Version:", "Date:", "From:", "To:", "Subject:", "Message-ID:",
            "Return-Path:", "Received:", "X-"
        ]
        
        return headerPatterns.contains { pattern in
            line.hasPrefix(pattern)
        }
    }
    
    /// Prüft ob eine Zeile eine Fortsetzung eines Headers ist
    private static func isHeaderContinuation(_ line: String) -> Bool {
        return line.hasPrefix(" ") || line.hasPrefix("\t")
    }
    
    /// Prüft ob eine Zeile eine MIME-Boundary ist (UNIVERSELL für alle Mail-Clients)
    private static func isMIMEBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        // Muss mit "--" beginnen
        guard trimmed.hasPrefix("--") else {
            return false
        }
        
        // "---" ist kein Boundary (oft in Signaturen)
        if trimmed.hasPrefix("---") {
            return false
        }
        
        // Nur "--" alleine ist auch kein Boundary
        if trimmed == "--" {
            return false
        }
        
        // Apple Mail Pattern: --Apple-Mail=...
        if trimmed.contains("Apple-Mail") {
            return true
        }
        
        // Gmail/Standard Pattern: --00000000000085ab2806427bec51--
        // Closing boundary endet mit "--"
        if trimmed.hasSuffix("--") && trimmed.count > 4 {
            let middle = String(trimmed.dropFirst(2).dropLast(2))
            let isAlphanumeric = middle.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "=" }
            if isAlphanumeric && middle.count >= 10 {
                return true
            }
        }
        
        // Standard MIME Boundary Pattern: --{boundary_string}
        // Typisch: mindestens 10 Zeichen, alphanumerisch + Sonderzeichen
        let boundary = String(trimmed.dropFirst(2))
        if boundary.count >= 10 {
            let validBoundaryChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-="))
            let validCount = boundary.unicodeScalars.filter { validBoundaryChars.contains($0) }.count
            if Double(validCount) / Double(boundary.count) >= 0.7 {
                return true
            }
        }
        
        return false
    }
    
    /// ✅ PHASE 3: Leichte MIME-Boundary-Filterung für Straggler (MIME-Parser macht das Meiste)
    private static func removeStragglerMIMEBoundaries(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Nur offensichtliche Boundaries entfernen, die durchgerutscht sind
            if isMIMEBoundary(trimmed) {
                print("🧹 PHASE 3: Removing straggler boundary: \(trimmed)")
                continue
            }
            
            cleanedLines.append(line)
        }
        
        return cleanedLines.joined(separator: "\n")
    }
    
    /// Entfernt/Normalisiert HTML-Meta-Tags
    private static func cleanHTMLMetaTags(_ content: String) -> String {
        var content = content
        
        // Entferne DOCTYPE deklarationen (oft doppelt oder falsch platziert)
        let doctypePattern = "<!DOCTYPE[^>]*>"
        content = content.replacingOccurrences(
            of: doctypePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Entferne problematische Content-Type Meta-Tags
        let metaContentTypePattern = "<meta[^>]*http-equiv=['\"]Content-Type['\"][^>]*>"
        content = content.replacingOccurrences(
            of: metaContentTypePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return content
    }
    
    /// Legacy: Normalisiert nicht-druckbare Zeichen (HTML-Entities werden von HTMLEntityDecoder behandelt)
    private static func normalizeSonderzeichen(_ content: String) -> String {
        // Nur noch nicht-druckbare Zeichen entfernen
        return content.replacingOccurrences(
            of: "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]",
            with: "",
            options: .regularExpression
        )
    }
    
    /// Normalisiert Zeilenumbrüche
    private static func normalizeLineBreaks(_ content: String) -> String {
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
    
    /// Entfernt übermäßige Leerzeilen und Whitespace
    private static func removeExcessiveWhitespace(_ content: String) -> String {
        // Reduziere mehrfache Leerzeilen auf maximal 2
        let multipleNewlines = "\n{3,}"
        var cleaned = content.replacingOccurrences(
            of: multipleNewlines,
            with: "\n\n",
            options: .regularExpression
        )
        
        // Entferne trailing/leading whitespace pro Zeile
        let lines = cleaned.components(separatedBy: .newlines)
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        cleaned = trimmedLines.joined(separator: "\n")
        
        // Entferne leading/trailing whitespace vom gesamten Content
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    /// Entfernt einzelne Sonderzeichen am Ende
    private static func removeTrailingOrphans(_ text: String) -> String {
        var cleaned = text
        
        // Liste von Sonderzeichen die alleine am Ende nichts zu suchen haben
        let trailingOrphans = [")", "(", "]", "[", "}", "{", ">", "<", "|", "\\", "/", ";", ":", ","]
        
        // Entferne trailing Orphans (wenn sie alleine in der letzten Zeile stehen)
        let lines = cleaned.components(separatedBy: .newlines)
        if let lastLine = lines.last {
            let trimmedLast = lastLine.trimmingCharacters(in: .whitespaces)
            // Wenn letzte Zeile nur aus einem einzelnen Sonderzeichen besteht
            if trimmedLast.count == 1 && trailingOrphans.contains(trimmedLast) {
                // Entferne diese Zeile
                let withoutLast = lines.dropLast()
                cleaned = withoutLast.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        return cleaned
    }
    
    /// Entfernt MIME-Boundaries die versehentlich im HTML gelandet sind
    private static func removeMIMEBoundariesFromHTML(_ html: String) -> String {
        var lines = html.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Überspringe MIME-Boundaries
            if isMIMEBoundary(trimmed) {
                continue
            }
            
            // Überspringe Zeilen die hauptsächlich aus Quoted-Printable Codes bestehen
            // (nur noch relevant für nicht-dekodierte Reste)
            if trimmed.contains("=") && trimmed.range(of: "=[0-9A-Fa-f]{2}", options: .regularExpression) != nil {
                let equals = trimmed.components(separatedBy: "=").count - 1
                // Wenn mehr als 50% der Zeile aus "=XX" Codes besteht, überspringe sie
                if equals > 5 && Double(equals) / Double(trimmed.count) * 3 > 0.3 {
                    continue
                }
            }
            
            cleanedLines.append(line)
        }
        
        return cleanedLines.joined(separator: "\n")
    }
    
    /// Entfernt MIME-Header vom Anfang des Contents (charset=, boundary=, etc.)
    private static func removeMIMEHeadersFromStart(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var startIndex = 0
        
        // Suche nach der ersten Zeile die KEIN MIME-Header ist
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // MIME-Header-Muster
            if trimmed.hasPrefix("charset=") ||
               trimmed.hasPrefix("boundary=") ||
               trimmed.hasPrefix("Content-Type:") ||
               trimmed.hasPrefix("Content-Transfer-Encoding:") ||
               trimmed.isEmpty && index < 3 {
                startIndex = index + 1
                continue
            }
            
            // Erste Nicht-MIME-Zeile gefunden
            break
        }
        
        // Entferne alle MIME-Header-Zeilen vom Anfang
        if startIndex > 0 && startIndex < lines.count {
            let cleanedLines = Array(lines.dropFirst(startIndex))
            return cleanedLines.joined(separator: "\n")
        }
        
        return content
    }
    
    /// Entfernt MIME-Boundaries vom Ende des Contents (UNIVERSELL)
    private static func removeMIMEBoundariesFromEnd(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var endIndex = lines.count
        var foundBoundary = false
        
        // Suche rückwärts nach MIME-Boundaries
        for (index, line) in lines.enumerated().reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // MIME-Boundary erkannt
            if isMIMEBoundary(trimmed) {
                endIndex = index
                foundBoundary = true
                continue
            }
            
            // Leere Zeilen nur entfernen wenn sie NACH einer erkannten Boundary kommen
            if foundBoundary && trimmed.isEmpty {
                endIndex = index
                continue
            }
            
            // Erste Nicht-Boundary-Zeile gefunden - stoppe
            if !trimmed.isEmpty {
                break
            }
        }
        
        // Entferne alle Boundary-Zeilen vom Ende
        if endIndex < lines.count {
            let cleanedLines = Array(lines.prefix(endIndex))
            return cleanedLines.joined(separator: "\n")
        }
        
        return content
    }
    
    /// Stellt sicher, dass HTML minimale Struktur hat
    private static func ensureMinimalHTMLStructure(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Wenn bereits vollständige HTML-Struktur vorhanden
        if trimmed.lowercased().contains("<html") && trimmed.lowercased().contains("</html>") {
            return html
        }
        
        // Wenn body-Tag vorhanden, aber kein html-Tag
        if trimmed.lowercased().contains("<body") && !trimmed.lowercased().contains("<html") {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; 
                           font-size: 14px; line-height: 1.6; padding: 12px; }
                </style>
            </head>
            \(html)
            </html>
            """
        }
        
        // Wenn nur Content-Fragmente vorhanden, wrappe in vollständige Struktur
        if !trimmed.lowercased().contains("<body") {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; 
                           font-size: 14px; line-height: 1.6; padding: 12px; 
                           word-wrap: break-word; }
                </style>
            </head>
            <body>
            \(html)
            </body>
            </html>
            """
        }
        
        return html
    }
}
