// MailBodyProcessor.swift - Zentrale Helper-Funktion für RAW → HTML Dekodierung
// Einmalig aufgerufen beim ersten Laden oder durch Toggle
import Foundation

/// Zentrale Helper-Funktion für RAW → HTML Dekodierung
/// Einmalig aufgerufen beim ersten Laden oder durch Toggle
public class MailBodyProcessor {
    
    /// Prüft ob Body noch MIME-Kodierung enthält
    public static func needsProcessing(_ body: String?) -> Bool {
        guard let body = body, !body.isEmpty else { return true }
        
        // Prüfe erste 10 Zeilen auf MIME-Header
        let lines = body.components(separatedBy: .newlines).prefix(10)
        for line in lines {
            let lower = line.lowercased()
            if lower.contains("content-type:") ||
               lower.contains("content-transfer-encoding:") ||
               lower.hasPrefix("--") { // Boundary
                return true
            }
        }
        
        return false
    }
    
    /// Dekodiert rawBody zu text/html
    public static func processRawBody(_ rawBody: String) -> (text: String?, html: String?) {
        print("🔄 [MailBodyProcessor] Processing rawBody (\(rawBody.count) chars)...")
        
        // Schritt 1: MIMEParser nutzen
        let mimeParser = MIMEParser()
        let mimeContent = mimeParser.parse(
            rawBodyBytes: nil,
            rawBodyString: rawBody,
            contentType: extractContentType(rawBody),
            charset: extractCharset(rawBody)
        )
        
        print("   - MIME parsed: text=\(mimeContent.text?.count ?? 0), html=\(mimeContent.html?.count ?? 0)")
        
        // Schritt 2: Minimale Nachbearbeitung für bereits geparstes MIME
        // WICHTIG: MIMEParser hat bereits sauber extrahiert - nur finale Politur nötig
        var processedText: String? = nil
        var processedHtml: String? = nil
        
        if let html = mimeContent.html {
            processedHtml = cleanAlreadyParsedHTML(html)
            print("   - HTML cleaned: \(processedHtml?.count ?? 0) chars")
        }
        
        if let text = mimeContent.text {
            processedText = cleanAlreadyParsedText(text)
            print("   - Text cleaned: \(processedText?.count ?? 0) chars")
        }
        
        return (processedText, processedHtml)
    }
    
    // MARK: - Minimale Cleanup-Methoden für bereits geparstes MIME
    
    /// Minimale HTML-Bereinigung für bereits durch MIMEParser extrahiertes HTML
    private static func cleanAlreadyParsedHTML(_ html: String) -> String {
        var content = html
        
        // Nur minimale Bereinigung - MIMEParser hat bereits die Hauptarbeit geleistet
        
        // 1. Entferne mögliche verbliebene E-Mail-Header am Anfang (selten, aber möglich)
        content = removeLeadingEmailHeaders(content)
        
        // 2. Trimme Whitespace
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return content
    }
    
    /// Minimale Text-Bereinigung für bereits durch MIMEParser extrahierten Text
    private static func cleanAlreadyParsedText(_ text: String) -> String {
        var content = text
        
        // Nur minimale Bereinigung - MIMEParser hat bereits die Hauptarbeit geleistet
        
        // 1. Entferne mögliche verbliebene E-Mail-Header am Anfang (selten, aber möglich)
        content = removeLeadingEmailHeaders(content)
        
        // 2. Normalisiere Zeilenumbrüche
        content = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        // 3. Reduziere übermäßige Leerzeilen (mehr als 3 → 2)
        let multipleNewlines = "\n{4,}"
        content = content.replacingOccurrences(
            of: multipleNewlines,
            with: "\n\n",
            options: .regularExpression
        )
        
        // 4. Trimme Whitespace
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return content
    }
    
    /// Entfernt mögliche E-Mail-Header am Anfang des Contents
    private static func removeLeadingEmailHeaders(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var contentStartIndex = 0
        var inHeaderSection = false
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Leere Zeile könnte Header-Ende markieren
            if trimmed.isEmpty && index > 0 {
                if inHeaderSection {
                    contentStartIndex = index + 1
                    break
                }
            } else if isEmailHeaderLine(trimmed) {
                inHeaderSection = true
            } else if inHeaderSection && !trimmed.isEmpty {
                // Nicht-Header-Zeile gefunden - Header-Section endet
                contentStartIndex = index
                break
            }
        }
        
        // Wenn Header gefunden, entferne sie
        if contentStartIndex > 0 && contentStartIndex < lines.count {
            let contentLines = Array(lines[contentStartIndex...])
            return contentLines.joined(separator: "\n")
        }
        
        return content
    }
    
    private static func isEmailHeaderLine(_ line: String) -> Bool {
        let headerPatterns = [
            "Content-Type:", "Content-Transfer-Encoding:", "Content-Disposition:",
            "MIME-Version:", "Date:", "From:", "To:", "Subject:", "Message-ID:",
            "Return-Path:", "Received:", "Delivered-To:", "X-"
        ]
        return headerPatterns.contains { pattern in line.hasPrefix(pattern) }
    }
    
    // MARK: - Content-Type/Charset Extraktion
    
    private static func extractContentType(_ rawBody: String) -> String? {
        let lines = rawBody.components(separatedBy: .newlines).prefix(50)
        for line in lines {
            if line.lowercased().hasPrefix("content-type:") {
                let value = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces)
                return value.split(separator: ";").first.map(String.init)
            }
        }
        return nil
    }
    
    private static func extractCharset(_ rawBody: String) -> String? {
        let lines = rawBody.components(separatedBy: .newlines).prefix(50)
        for line in lines {
            if line.lowercased().contains("charset=") {
                if let range = line.range(of: "charset=", options: .caseInsensitive) {
                    let charsetPart = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                    if let firstPart = charsetPart.split(separator: ";").first {
                        return String(firstPart).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    }
                }
            }
        }
        return nil
    }
}
