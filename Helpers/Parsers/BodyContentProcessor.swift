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
        
        // Schritt 3: Normalisiere Sonderzeichen
        content = normalizeSonderzeichen(content)
        
        // Schritt 4: Sichere minimale HTML-Struktur
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
        
        return content
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
        
        // Erkenne Header-Section am Anfang
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
        
        // Entferne Header-Zeilen
        if headerEndIndex > 0 && headerEndIndex < lines.count {
            lines.removeFirst(headerEndIndex)
        }
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Private Helper Methods
    
    /// Erkennt E-Mail-Header-Zeilen
    private static func isEmailHeaderLine(_ line: String) -> Bool {
        let headerPrefixes = [
            "From:", "To:", "Cc:", "Bcc:", "Subject:", "Date:",
            "Return-Path:", "Received:", "Message-ID:", "Message-Id:",
            "In-Reply-To:", "References:", "MIME-Version:",
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
