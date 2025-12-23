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
        
        // ✅ Schritt 0: Quoted-Printable Decoding ZUERST
        content = decodeQuotedPrintableIfNeeded(content)
        
        // ✅ NEU: MIME-Boundaries und Header entfernen (KRITISCH!)
        content = removeMIMEBoundariesAndHeaders(content)
        
        // ✅ Schritt 0.5: Entferne MIME-Header am Anfang
        content = removeMIMEHeadersFromStart(content)
        
        // Schritt 1: Entferne E-Mail-Header aus Body
        content = removeEmailHeaders(content)
        
        // Schritt 2: Entferne/Normalisiere HTML-Meta-Tags
        content = cleanHTMLMetaTags(content)
        
        // Schritt 3: Decode HTML-Entities
        content = HTMLEntityDecoder.decodeForHTML(content)
        
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
        
        // ✅ Schritt 0: Quoted-Printable Decoding ZUERST
        content = decodeQuotedPrintableIfNeeded(content)
        
        // ✅ NEU: MIME-Boundaries und Header entfernen
        content = removeMIMEBoundariesAndHeaders(content)
        
        // Schritt 1: Entferne E-Mail-Header aus Body
        content = removeEmailHeaders(content)
        
        // Schritt 2: Normalisiere Zeilenumbrüche
        content = normalizeLineBreaks(content)
        
        // Schritt 3: Decode HTML-Entities
        content = HTMLEntityDecoder.decodeForPlainText(content)
        
        // Schritt 4: Normalisiere Sonderzeichen
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

        // Schritt 1: Quoted-Printable Decoding (auch für gecachte Mails mit Umlauten)
        content = decodeQuotedPrintableIfNeeded(content)

        // Schritt 2: Entferne verwaiste Meta-Tag-Fragmente (auch für gecachte Mails)
        content = cleanHTMLMetaTags(content)

        // Schritt 3: Konvertiere Wingdings-Emoticons zu Unicode-Emojis
        content = convertWingdingsToEmoji(content)

        // Schritt 4: Sichere minimale HTML-Struktur (falls noch nicht vorhanden)
        content = ensureMinimalHTMLStructure(content)

        // Schritt 5: Letzte Cleanup-Phase für Anzeige
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        return content
    }
    
    // MARK: - PHASE 3: HTML Finalization with CID rewriting
    
    /// Finale HTML-Verarbeitung mit CID-Rewriting für Inline-Bilder
    /// - Parameters:
    ///   - html: Der zu verarbeitende HTML-Content
    ///   - messageId: Die Message-ID für URL-Generierung
    ///   - mimeParts: Array der MIME-Parts für CID-Lookup
    /// - Returns: Finalisierter HTML mit umgeschriebenen CID-Referenzen
    public static func finalizeHtml(_ html: String, messageId: UUID, mimeParts: [MIMEParser.MimePartEntity]) -> String {
        var result = html
        
        // Phase 1: Rewrite CID references für Inline-Bilder
        let pattern = #"cid:([^"\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            print("⚠️ BodyContentProcessor: Failed to create CID regex")
            return sanitizeHtml(result)
        }
        
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        print("🔍 BodyContentProcessor: Found \(matches.count) CID references")
        
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: html) {
                let contentId = String(html[range])
                
                // Find part with this content-id
                if let part = mimeParts.first(where: { $0.contentId == contentId }) {
                    let newUrl = "/mail/\(messageId)/cid/\(contentId)"
                    let fullRange = Range(match.range, in: html)!
                    result.replaceSubrange(fullRange, with: newUrl)
                    print("✅ BodyContentProcessor: Rewrote CID \(contentId) → \(newUrl)")
                } else {
                    print("⚠️ BodyContentProcessor: CID not found in parts: \(contentId)")
                }
            }
        }
        
        // Phase 2: Sanitize HTML
        result = sanitizeHtml(result)
        
        return result
    }
    
    /// Sanitisiert HTML für sichere Anzeige
    /// - Parameter html: Der zu bereinigende HTML-Content
    /// - Returns: Sanitisierter HTML-Content
    private static func sanitizeHtml(_ html: String) -> String {
        var sanitized = html
        
        // Entferne script tags (Sicherheit)
        sanitized = sanitized.replacingOccurrences(
            of: #"<script[^>]*>.*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        
        // Blockiere externe Ressourcen (Privacy)
        sanitized = sanitized.replacingOccurrences(
            of: #"https?://[^"\s]+"#,
            with: "#blocked",
            options: .regularExpression
        )
        
        // Entferne potentiell gefährliche Event-Handler
        let dangerousEvents = ["onclick", "onload", "onerror", "onmouseover", "onmouseout"]
        for event in dangerousEvents {
            let pattern = "\(event)\\s*=\\s*[\"'][^\"']*[\"']"
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        
        // Entferne javascript: URLs
        sanitized = sanitized.replacingOccurrences(
            of: #"javascript:[^"\s]*"#,
            with: "#blocked",
            options: [.regularExpression, .caseInsensitive]
        )
        
        return sanitized
    }
    
    /// Finale Bereinigung für bereits verarbeiteten Plain-Text (minimaler Overhead)
    /// - Parameter text: Bereits durch MIME-Parsing und cleanPlainTextForDisplay verarbeiteter Text
    /// - Returns: Final bereinigter Plain-Text-Content für Anzeige
    private static func finalizePlainTextForDisplay(_ text: String) -> String {
        var content = text

        // Schritt 1: Quoted-Printable Decoding (auch für gecachte Mails)
        content = decodeQuotedPrintableIfNeeded(content)

        // Schritt 2: Finale Whitespace-Bereinigung
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Schritt 3: Stelle sicher dass nicht komplett leer
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
        // ✅ Prüfe zuerst: Wenn bereits korrekte UTF-8 Umlaute vorhanden, NICHT dekodieren!
        // Dies verhindert Doppel-Dekodierung von bereits korrektem Content
        let hasValidUmlauts = content.contains("ä") || content.contains("ö") || content.contains("ü") ||
                              content.contains("Ä") || content.contains("Ö") || content.contains("Ü") ||
                              content.contains("ß")
        if hasValidUmlauts {
            // Content hat bereits korrekte Umlaute - nicht dekodieren
            return content
        }

        // Prüfe auf SPEZIFISCHE QP-Patterns für deutsche Umlaute (ISO-8859-1)
        // =FC=ü, =E4=ä, =F6=ö, =DF=ß, =DC=Ü, =C4=Ä, =D6=Ö
        let germanQPPatterns = ["=FC", "=fc", "=E4", "=e4", "=F6", "=f6",
                                "=DF", "=df", "=DC", "=dc", "=C4", "=c4", "=D6", "=d6"]
        let hasGermanQP = germanQPPatterns.contains { content.contains($0) }

        // Oder: =3D (escaped =) ist ein starkes QP-Indiz
        let hasEscapedEquals = content.contains("=3D") || content.contains("=3d")

        // Oder: Soft line breaks (=\r\n oder = am Zeilenende)
        let hasSoftLineBreak = content.contains("=\r\n") || content.contains("=\n")

        guard hasGermanQP || hasEscapedEquals || hasSoftLineBreak else {
            return content
        }

        print("🔄 BodyContentProcessor: Quoted-Printable detected, decoding...")

        // Nutze QuotedPrintableDecoder (bereits vorhanden im Projekt)
        let decoded = QuotedPrintableDecoder.decode(content, charset: "utf-8")

        print("✅ BodyContentProcessor: Decoded \(content.count) → \(decoded.count) chars")

        return decoded
    }
    
    // MARK: - Private Helper Methods
    
    /// ✅ NEU: Zentrale Methode zum Entfernen von MIME-Artefakten
    /// Entfernt MIME-Boundaries und technische Header aus bereits dekodiertem Content
    /// - Parameter content: Der zu bereinigende Content
    /// - Returns: Content ohne MIME-Boundaries und technische Header
    private static func removeMIMEBoundariesAndHeaders(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        var cleanedLines: [String] = []
        var inHeaderBlock = false
        var emptyLinesSinceHeader = 0
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // MIME-Boundary erkannt - überspringe diese Zeile
            if trimmed.hasPrefix("--") && (
                trimmed.contains("Apple-Mail") ||
                trimmed.contains("boundary") ||
                trimmed.range(of: "^--[A-Za-z0-9_=-]+$", options: .regularExpression) != nil
            ) {
                print("🧹 removeMIMEBoundariesAndHeaders: Removing boundary: \(trimmed)")
                inHeaderBlock = true
                emptyLinesSinceHeader = 0
                continue
            }
            
            // Technische Header in Body-Section
            if trimmed.hasPrefix("Content-Type:") ||
               trimmed.hasPrefix("Content-Transfer-Encoding:") ||
               trimmed.hasPrefix("Content-Disposition:") ||
               trimmed.hasPrefix("MIME-Version:") ||
               (trimmed.hasPrefix("charset=") && inHeaderBlock) {
                print("🧹 removeMIMEBoundariesAndHeaders: Removing header: \(trimmed)")
                inHeaderBlock = true
                emptyLinesSinceHeader = 0
                continue
            }
            
            // Leere Zeile - könnte Header-Ende sein
            if trimmed.isEmpty {
                if inHeaderBlock {
                    emptyLinesSinceHeader += 1
                    // Nach 1 Leerzeile endet der Header-Block
                    if emptyLinesSinceHeader >= 1 {
                        inHeaderBlock = false
                        emptyLinesSinceHeader = 0
                    }
                    continue
                } else {
                    // Normale Leerzeile im Content
                    cleanedLines.append(line)
                }
                continue
            }
            
            // Nicht-leere Zeile
            if !inHeaderBlock {
                // Normale Content-Zeile
                cleanedLines.append(line)
            } else {
                // Noch im Header-Block (z.B. Header-Continuation)
                emptyLinesSinceHeader = 0
            }
        }
        
        return cleanedLines.joined(separator: "\n")
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
    
    /// ✅ PHASE 3: Leichte MIME-Boundary-Filterung für Straggler (nutzt zentrale Methode)
    private static func removeStragglerMIMEBoundaries(_ content: String) -> String {
        return removeMIMEBoundariesAndHeaders(content)
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

        // ✅ NEU: Entferne verwaiste DTD/URL-Fragmente (z.B. //www.w3.org/TR/REC-html40">)
        // Diese entstehen wenn DOCTYPE teilweise entfernt wurde
        let orphanedDTDPattern = "(?m)^\\s*//www\\.w3\\.org[^>]*>"
        content = content.replacingOccurrences(
            of: orphanedDTDPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Entferne problematische Content-Type Meta-Tags (mit Quotes)
        let metaContentTypePattern = "<meta[^>]*http-equiv=['\"]Content-Type['\"][^>]*>"
        content = content.replacingOccurrences(
            of: metaContentTypePattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Entferne Content-Type Meta-Tags ohne Quotes
        let metaContentTypeNoQuotes = "<meta[^>]*http-equiv=Content-Type[^>]*>"
        content = content.replacingOccurrences(
            of: metaContentTypeNoQuotes,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // ✅ NEU: Entferne verwaiste Meta-Tag-Fragmente (wenn <meta bereits fehlt)
        // Pattern: http-equiv=Content-Type ... charset=... bis zum >
        // [\s\S]*? matcht alle Zeichen inkl. Newlines (non-greedy)
        let orphanedMetaPattern = "http-equiv[\\s\\S]*?Content-Type[\\s\\S]*?>"
        content = content.replacingOccurrences(
            of: orphanedMetaPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Zusätzlich: Pattern für Fragmente die mit charset= beginnen (am Zeilenanfang)
        let orphanedCharsetStartPattern = "(?m)^\\s*charset=[^>]*>"
        content = content.replacingOccurrences(
            of: orphanedCharsetStartPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // ✅ NEU: Entferne auch charset-Fragmente ohne Meta-Tag
        // (?m) aktiviert multiline mode für ^ und $ anchors
        let orphanedCharsetPattern = "(?m)^\\s*charset=[^>\\s]+[>;]?\\s*$"
        content = content.replacingOccurrences(
            of: orphanedCharsetPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // ✅ NEU: Entferne versehentlich gespeicherte Debug-Fragmente (z.B. "UID 1234)")
        let debugUIDPattern = "\\s*UID\\s*\\d+\\)?\\s*$"
        content = content.replacingOccurrences(
            of: debugUIDPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return content
    }

    /// Konvertiert Wingdings-Emoticons zu Unicode-Emojis
    /// Windows/Outlook verwendet Wingdings-Font für Emoticons: J=😊, L=😞, K=😐
    private static func convertWingdingsToEmoji(_ content: String) -> String {
        var result = content

        // Pattern für Wingdings-Spans: <span style="...Wingdings...">J</span>
        // Auch mit font-family: Wingdings oder font-family:"Wingdings"
        let wingdingsPatterns = [
            // J = Smiley 😊
            ("(?i)<span[^>]*font-family[^>]*[Ww]ingdings[^>]*>\\s*J\\s*</span>", "😊"),
            ("(?i)<span[^>]*[Ww]ingdings[^>]*>\\s*J\\s*</span>", "😊"),
            // L = Frowny 😞
            ("(?i)<span[^>]*font-family[^>]*[Ww]ingdings[^>]*>\\s*L\\s*</span>", "😞"),
            ("(?i)<span[^>]*[Ww]ingdings[^>]*>\\s*L\\s*</span>", "😞"),
            // K = Neutral 😐
            ("(?i)<span[^>]*font-family[^>]*[Ww]ingdings[^>]*>\\s*K\\s*</span>", "😐"),
            ("(?i)<span[^>]*[Ww]ingdings[^>]*>\\s*K\\s*</span>", "😐")
        ]

        for (pattern, emoji) in wingdingsPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: emoji,
                options: .regularExpression
            )
        }

        // Fallback: Einzelne J/L/K nach Wingdings-Font-Deklaration (ohne Span)
        // z.B. wenn der Font im Parent-Element gesetzt ist
        if result.lowercased().contains("wingdings") {
            // Ersetze alleinstehende J/L/K nur wenn Wingdings im Kontext erwähnt wird
            // Dies ist konservativer um normale J/L/K nicht zu ersetzen
            result = result.replacingOccurrences(
                of: "(?i)(wingdings[^<]{0,50})J",
                with: "$1😊",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "(?i)(wingdings[^<]{0,50})L",
                with: "$1😞",
                options: .regularExpression
            )
            result = result.replacingOccurrences(
                of: "(?i)(wingdings[^<]{0,50})K",
                with: "$1😐",
                options: .regularExpression
            )
        }

        return result
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
    
    /// Entfernt einzelne Sonderzeichen am Ende (z.B. einsame Klammern)
    private static func removeTrailingOrphans(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Liste von Sonderzeichen die alleine am Ende nichts zu suchen haben
        let trailingOrphans = [")", "(", "]", "[", "}", "{", ">", "<", "|", "\\", "/", ";", ":", ","]
        
        // ✅ NEU: Prüfe die letzten 3 Zeilen, nicht nur die letzte
        let lines = cleaned.components(separatedBy: .newlines)
        var linesToKeep = lines
        
        // Entferne trailing orphan Zeilen (von hinten nach vorne)
        for _ in 0..<min(3, lines.count) {
            guard let lastLine = linesToKeep.last else { break }
            let trimmedLast = lastLine.trimmingCharacters(in: .whitespaces)
            
            // ✅ NEU: Entferne auch leere Zeilen am Ende
            if trimmedLast.isEmpty {
                linesToKeep = Array(linesToKeep.dropLast())
                continue
            }
            
            // ✅ NEU: Prüfe ob Zeile NUR aus Orphan-Zeichen besteht (mehrere erlaubt)
            let orphanChars = trimmedLast.filter { trailingOrphans.contains(String($0)) }
            let isOnlyOrphans = orphanChars.count == trimmedLast.count && !trimmedLast.isEmpty
            
            if isOnlyOrphans && trimmedLast.count <= 3 {
                // Zeile besteht nur aus 1-3 Orphan-Zeichen → entfernen
                linesToKeep = Array(linesToKeep.dropLast())
            } else {
                // Normale Content-Zeile gefunden → stop
                break
            }
        }
        
        cleaned = linesToKeep.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
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
