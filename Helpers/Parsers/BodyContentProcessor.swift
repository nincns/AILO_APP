// BodyContentProcessor.swift
// Zentrale Klasse für Body-Content-Aufbereitung zur Anzeige
import Foundation

/// Prozessiert bereits dekodierten E-Mail-Body-Content für optimale Anzeige
///
/// Diese Klasse übernimmt die finale Aufbereitung von bereits dekodiertem Content:
/// - Entfernt technische E-Mail-Header aus Body
/// - Filtert HTML-Meta-Tags und DOCTYPE
/// - Normalisiert Sonderzeichen
/// - Unterscheidet Plain-Text vs HTML
public class BodyContentProcessor {
    
    // MARK: - Public API
    
    /// Bereitet HTML-Content für WebView-Anzeige auf
    /// - Parameter html: Bereits dekodierter HTML-String
    /// - Returns: Bereinigter HTML-Content
    public static func cleanHTMLForDisplay(_ html: String) -> String {
        var content = html
        
        // Schritt 1: Entferne E-Mail-Header aus Body (falls vorhanden)
        content = removeEmailHeaders(content)
        
        // Schritt 2: Entferne/Normalisiere HTML-Meta-Tags
        content = cleanHTMLMetaTags(content)
        
        // Schritt 3: Entferne rohe MIME-Boundaries aus HTML
        content = removeMIMEBoundariesFromHTML(content)
        
        // Schritt 4: Normalisiere Sonderzeichen
        content = normalizeSonderzeichen(content)
        
        // Schritt 5: Sichere minimale HTML-Struktur
        content = ensureMinimalHTMLStructure(content)
        
        return content
    }
    
    /// Bereitet Plain-Text-Content für TextView-Anzeige auf
    /// - Parameter text: Bereits dekodierter Plain-Text-String
    /// - Returns: Bereinigter Plain-Text-Content
    public static func cleanPlainTextForDisplay(_ text: String) -> String {
        var content = text
        
        // Schritt 1: Entferne E-Mail-Header aus Body
        content = removeEmailHeaders(content)
        
        // Schritt 2: Normalisiere Zeilenumbrüche
        content = normalizeLineBreaks(content)
        
        // Schritt 3: Normalisiere Sonderzeichen
        content = normalizeSonderzeichen(content)
        
        // Schritt 4: Entferne übermäßige Leerzeilen
        content = removeExcessiveWhitespace(content)
        
        // ✨ Schritt 5: Entferne einzelne Sonderzeichen am Ende
        content = removeTrailingOrphans(content)
        
        return content
    }
    
    /// Entscheidet welcher Content-Typ bevorzugt wird und liefert finalen Display-Content
    /// - Parameters:
    ///   - html: HTML-Content (optional)
    ///   - text: Plain-Text-Content (optional)
    /// - Returns: Tuple mit finalem Content und isHTML-Flag
    public static func selectDisplayContent(html: String?, text: String?) -> (content: String, isHTML: Bool) {
        // Priorität 1: HTML-Content
        if let htmlContent = html, !htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = cleanHTMLForDisplay(htmlContent)
            return (content: cleaned, isHTML: true)
        }
        
        // Priorität 2: Plain-Text
        if let textContent = text, !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = cleanPlainTextForDisplay(textContent)
            return (content: cleaned, isHTML: false)
        }
        
        // Kein Content
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
        
        // Phase 2: Entferne MIME-Boundaries und technische Zeilen im Content
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Überspringe MIME-Boundaries
            if isMIMEBoundary(trimmed) {
                continue
            }
            
            // Überspringe technische MIME-Zeilen im Body
            if isTechnicalMIMELine(trimmed) {
                continue
            }
            
            // Überspringe Apple-Mail technische Zeilen
            if trimmed.hasPrefix("--Apple-Mail=") || trimmed.contains("Apple-Mail=_") {
                continue
            }
            
            // Behalte alles andere
            cleanedLines.append(line)
        }
        
        return cleanedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private Helper Methods
    
    /// Erkennt E-Mail-Header-Zeilen
    private static func isEmailHeaderLine(_ line: String) -> Bool {
        let headerPrefixes = [
            "From:", "To:", "Cc:", "Bcc:", "Subject:", "Date:",
            "Return-Path:", "Received:", "Message-ID:", "Message-Id:",
            "In-Reply-To:", "References:", "MIME-Version:", "Mime-Version:",
            "Content-Type:", "Content-Transfer-Encoding:",
            "X-", "Delivered-To:", "Reply-To:", "Sender:",
            "List-", "Precedence:", "Priority:", "Importance:"
        ]
        
        for prefix in headerPrefixes {
            if line.hasPrefix(prefix) || line.lowercased().hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        
        return false
    }
    
    /// Erkennt Header-Fortsetzungszeilen (beginnen mit Whitespace)
    private static func isHeaderContinuation(_ line: String) -> Bool {
        return line.hasPrefix(" ") || line.hasPrefix("\t")
    }
    
    /// ✨ NEUE METHODE: Erkennt MIME-Boundary-Zeilen
    private static func isMIMEBoundary(_ line: String) -> Bool {
        // MIME Boundaries beginnen mit "--" und enthalten oft "boundary" oder lange IDs
        if line.hasPrefix("--") {
            // Typische Boundary-Muster
            if line.contains("boundary") ||
               line.contains("Apple-Mail") ||
               line.contains("_") && line.count > 20 {
                return true
            }
            
            // Ende-Boundary (endet mit "--")
            if line.hasSuffix("--") && line.count > 4 {
                return true
            }
        }
        
        return false
    }
    
    /// ✨ NEUE METHODE: Erkennt technische MIME-Zeilen im Body
    private static func isTechnicalMIMELine(_ line: String) -> Bool {
        let technicalPatterns = [
            "Content-Type:",
            "Content-Transfer-Encoding:",
            "Content-Disposition:",
            "Content-ID:",
            "MIME-Version:",
            "Mime-Version:",
            "charset=",
            "boundary=",
            "name=",
            "filename="
        ]
        
        for pattern in technicalPatterns {
            if line.hasPrefix(pattern) || line.contains(pattern) && line.count < 200 {
                return true
            }
        }
        
        // Quoted-Printable kodierte Zeilen (z.B. =E2=80=93)
        if line.contains("=") && line.range(of: "=[0-9A-F]{2}", options: .regularExpression) != nil {
            // Aber nur wenn die Zeile hauptsächlich aus Codes besteht
            let codeMatches = line.components(separatedBy: "=").count - 1
            if codeMatches > 5 && line.count < 100 {
                return true
            }
        }
        
        return false
    }
    
    /// Bereinigt HTML-Meta-Tags und DOCTYPE
    private static func cleanHTMLMetaTags(_ html: String) -> String {
        var content = html
        
        // Entferne DOCTYPE deklarationen
        let doctypePattern = "<!DOCTYPE[^>]*>"
        content = content.replacingOccurrences(
            of: doctypePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Entferne problematische meta-tags (charset-Konflikte)
        let metaCharsetPattern = "<meta[^>]*charset[^>]*>"
        content = content.replacingOccurrences(
            of: metaCharsetPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Entferne meta content-type tags
        let metaContentTypePattern = "<meta[^>]*http-equiv=[\"']?content-type[\"']?[^>]*>"
        content = content.replacingOccurrences(
            of: metaContentTypePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return content
    }
    
    /// Normalisiert Sonderzeichen und HTML-Entities
    private static func normalizeSonderzeichen(_ content: String) -> String {
        var normalized = content
        
        // Häufige HTML-Entities
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&lt;": "<",
            "&gt;": ">",
            "&amp;": "&",
            "&quot;": "\"",
            "&apos;": "'",
            "&#8211;": "–",
            "&#8212;": "—",
            "&#8220;": "\u{201C}",  // " (left double quotation mark)
            "&#8221;": "\u{201D}",  // " (right double quotation mark)
            "&#8216;": "\u{2018}",  // ' (left single quotation mark)
            "&#8217;": "\u{2019}",  // ' (right single quotation mark),
            "&auml;": "ä",
            "&ouml;": "ö",
            "&uuml;": "ü",
            "&Auml;": "Ä",
            "&Ouml;": "Ö",
            "&Uuml;": "Ü",
            "&szlig;": "ß",
            "&euro;": "€"
        ]
        
        for (entity, replacement) in entities {
            normalized = normalized.replacingOccurrences(of: entity, with: replacement)
        }
        
        // Normalisiere nicht-druckbare Zeichen
        normalized = normalized.replacingOccurrences(
            of: "[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]",
            with: "",
            options: .regularExpression
        )
        
        return normalized
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
    
    /// ✨ NEUE METHODE: Entfernt einzelne Sonderzeichen am Ende
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
    
    /// ✨ NEUE METHODE: Entfernt MIME-Boundaries die versehentlich im HTML gelandet sind
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
