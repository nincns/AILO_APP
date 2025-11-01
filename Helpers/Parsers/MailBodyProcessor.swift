// MailBodyProcessor.swift - Zentrale Helper-Funktion für RAW → HTML Dekodierung
// Einmalig aufgerufen beim ersten Laden oder durch Toggle
import Foundation

/// Zentrale Helper-Funktion für RAW → HTML Dekodierung
/// Einmalig aufgerufen beim ersten Laden oder durch Toggle
public class MailBodyProcessor {
    
    /// Prüft ob Body noch MIME-Kodierung enthält
    /// WICHTIG: Unterscheidet zwischen RAW (mit Boundaries) und verarbeitetem Content
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
    
    // MARK: - Minimale Cleanup-Methoden
    
    private static func cleanAlreadyParsedHTML(_ html: String) -> String {
        var content = html
        content = removeLeadingEmailHeaders(content)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content
    }
    
    private static func cleanAlreadyParsedText(_ text: String) -> String {
        var content = text
        content = removeLeadingEmailHeaders(content)
        content = content.replacingOccurrences(of: "\r\n", with: "\n")
        content = content.replacingOccurrences(of: "\r", with: "\n")
        
        let multipleNewlines = "\n{4,}"
        content = content.replacingOccurrences(of: multipleNewlines, with: "\n\n", options: .regularExpression)
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content
    }
    
    private static func removeLeadingEmailHeaders(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var contentStartIndex = 0
        var inHeaderSection = false
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.isEmpty && index > 0 {
                if inHeaderSection {
                    contentStartIndex = index + 1
                    break
                }
            } else if isEmailHeaderLine(trimmed) {
                inHeaderSection = true
            } else if inHeaderSection && !trimmed.isEmpty {
                contentStartIndex = index
                break
            }
        }
        
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
