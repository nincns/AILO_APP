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
        
        // Schritt 2: BodyContentProcessor für finale Bereinigung
        var processedText: String? = nil
        var processedHtml: String? = nil
        
        if let html = mimeContent.html {
            processedHtml = BodyContentProcessor.cleanHTMLForDisplay(html)
            print("   - HTML cleaned: \(processedHtml?.count ?? 0) chars")
        }
        
        if let text = mimeContent.text {
            processedText = BodyContentProcessor.cleanPlainTextForDisplay(text)
            print("   - Text cleaned: \(processedText?.count ?? 0) chars")
        }
        
        return (processedText, processedHtml)
    }
    
    // MARK: - Private Helpers
    
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