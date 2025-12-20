import Foundation

/// Zentraler Attachment-Extractor mit robustem MIME-Parsing
/// Unterstützt RFC 5322 Folded Headers und verschachtelte Multiparts
public class AttachmentExtractor {

    public struct ExtractedAttachment {
        public let filename: String
        public let mimeType: String
        public let data: Data
        public let contentId: String?
    }

    /// Extrahiert alle Anhänge aus Raw-Mail-Daten
    public static func extract(from rawBody: String) -> [ExtractedAttachment] {
        print("📎 [AttachmentExtractor] Starting extraction from \(rawBody.count) chars")

        guard let data = rawBody.data(using: .utf8) ?? rawBody.data(using: .isoLatin1) else {
            print("❌ [AttachmentExtractor] Failed to convert rawBody to Data")
            return []
        }
        return extract(from: data)
    }

    public static func extract(from data: Data) -> [ExtractedAttachment] {
        var results: [ExtractedAttachment] = []

        // 1. Headers und Body trennen (RFC-konform)
        let (headers, bodyStart) = parseMessageHeaders(data)

        print("📎 [AttachmentExtractor] Parsed \(headers.count) headers, body starts at \(bodyStart)")

        // 2. Content-Type und Boundary extrahieren
        guard let contentType = headers["content-type"],
              contentType.lowercased().contains("multipart") else {
            print("📎 [AttachmentExtractor] Not a multipart message")
            return []
        }

        guard let boundary = extractBoundary(from: contentType) else {
            print("❌ [AttachmentExtractor] No boundary found in: \(contentType.prefix(100))")
            return []
        }

        print("📎 [AttachmentExtractor] Found boundary: \(boundary.prefix(40))...")

        // 3. Rekursiv alle Parts verarbeiten
        let bodyData = data.dropFirst(bodyStart)
        extractFromMultipart(bodyData, boundary: boundary, results: &results, depth: 0)

        print("📎 [AttachmentExtractor] Total: \(results.count) attachments")
        return results
    }

    // MARK: - Private Helpers

    /// Parst Message-Headers unter Berücksichtigung von RFC 5322 Folded Headers
    private static func parseMessageHeaders(_ data: Data) -> ([String: String], Int) {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        var bodyStart = 0

        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ([:], 0)
        }

        var charCount = 0
        let lines = string.components(separatedBy: "\n")

        for line in lines {
            let lineLength = line.count + 1 // +1 für \n

            // Leerzeile = Ende der Headers
            let trimmedLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\t "))
            if trimmedLine.isEmpty {
                // Letzten Header speichern
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                bodyStart = charCount + lineLength
                break
            }

            // ✅ RFC 5322: Folded Header (beginnt mit Whitespace oder Tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                charCount += lineLength
                continue
            }

            // Neuer Header - vorherigen speichern
            if let key = currentKey {
                headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }

            // Header-Zeile parsen
            if let colonIndex = line.firstIndex(of: ":") {
                currentKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colonIndex)...])
            }

            charCount += lineLength
        }

        return (headers, bodyStart)
    }

    private static func extractBoundary(from contentType: String) -> String? {
        // Suche boundary= (mit oder ohne Quotes)
        let patterns = [
            "boundary=\"([^\"]+)\"",
            "boundary=([^;\\s\\r\\n]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: contentType, range: NSRange(contentType.startIndex..., in: contentType)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: contentType) {
                return String(contentType[range])
            }
        }
        return nil
    }

    private static func extractFromMultipart(_ data: Data.SubSequence, boundary: String, results: inout [ExtractedAttachment], depth: Int) {
        let indent = String(repeating: "  ", count: depth)

        guard let string = String(data: Data(data), encoding: .utf8) ?? String(data: Data(data), encoding: .isoLatin1) else {
            print("\(indent)❌ [AttachmentExtractor] Failed to decode multipart data")
            return
        }

        let delimiter = "--" + boundary
        let parts = string.components(separatedBy: delimiter)

        print("\(indent)📎 [AttachmentExtractor] Split into \(parts.count) parts with boundary")

        for (index, part) in parts.enumerated() {
            guard index > 0 else { continue } // Skip preamble
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && trimmed != "--" else { continue }

            print("\(indent)📎 [AttachmentExtractor] Processing part \(index)")
            processMultipartPart(part, results: &results, depth: depth)
        }
    }

    private static func processMultipartPart(_ part: String, results: inout [ExtractedAttachment], depth: Int) {
        let indent = String(repeating: "  ", count: depth)

        // Führende Newlines entfernen
        var cleanPart = part
        while cleanPart.hasPrefix("\r\n") { cleanPart = String(cleanPart.dropFirst(2)) }
        while cleanPart.hasPrefix("\n") { cleanPart = String(cleanPart.dropFirst(1)) }
        while cleanPart.hasPrefix("\r") { cleanPart = String(cleanPart.dropFirst(1)) }

        // ✅ FIX: Header/Body trennen mit RFC 5322 Folded Header Support
        guard let (headers, body) = splitHeadersAndBody(cleanPart) else {
            print("\(indent)📎 [AttachmentExtractor] No headers found in part")
            return
        }

        let contentType = headers["content-type"] ?? ""
        let encoding = headers["content-transfer-encoding"] ?? ""
        let disposition = headers["content-disposition"] ?? ""

        print("\(indent)📎 [AttachmentExtractor] Content-Type: \(contentType.prefix(60))...")

        // Rekursiv bei verschachteltem Multipart
        if contentType.lowercased().contains("multipart/") {
            if let nestedBoundary = extractBoundary(from: contentType),
               let bodyData = body.data(using: .utf8) {
                print("\(indent)📎 [AttachmentExtractor] Nested multipart with boundary: \(nestedBoundary.prefix(30))...")
                extractFromMultipart(bodyData[...], boundary: nestedBoundary, results: &results, depth: depth + 1)
            }
            return
        }

        // Attachment prüfen
        let isAttachment = disposition.lowercased().contains("attachment") ||
                          contentType.lowercased().contains("application/") ||
                          (contentType.lowercased().contains("image/") && disposition.lowercased().contains("attachment"))

        guard isAttachment else {
            print("\(indent)📎 [AttachmentExtractor] Not an attachment, skipping")
            return
        }

        // Filename extrahieren
        let filename = extractFilename(from: disposition) ?? extractFilename(from: contentType) ?? "attachment.bin"
        print("\(indent)📎 [AttachmentExtractor] Found attachment: \(filename)")

        // Base64 dekodieren
        if encoding.lowercased().contains("base64") {
            let base64 = body.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("--") }
                .joined()

            print("\(indent)📎 [AttachmentExtractor] Base64 length: \(base64.count) chars")

            if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty {
                // PDF-Integritätscheck
                if filename.lowercased().hasSuffix(".pdf") {
                    validatePDF(data, indent: indent)
                }

                results.append(ExtractedAttachment(
                    filename: filename,
                    mimeType: contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "application/octet-stream",
                    data: data,
                    contentId: headers["content-id"]
                ))
                print("\(indent)📎 [AttachmentExtractor] ✅ Decoded: \(filename) (\(data.count) bytes)")
            } else {
                print("\(indent)❌ [AttachmentExtractor] Failed to decode Base64 for \(filename)")
            }
        } else {
            print("\(indent)📎 [AttachmentExtractor] Not Base64 encoded, skipping")
        }
    }

    /// Trennt Headers und Body unter Berücksichtigung von RFC 5322 Folded Headers
    private static func splitHeadersAndBody(_ part: String) -> (headers: [String: String], body: String)? {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""

        let lines = part.components(separatedBy: "\n")
        var bodyStartIndex = 0

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\t "))

            // Leerzeile = Ende Headers
            if trimmedLine.isEmpty {
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                bodyStartIndex = index + 1
                break
            }

            // ✅ RFC 5322: Folded Header (beginnt mit Whitespace oder Tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }

            // Neuer Header - vorherigen speichern
            if let key = currentKey {
                headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }

            // Header-Zeile parsen
            if let colonIndex = line.firstIndex(of: ":") {
                currentKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colonIndex)...])
            }
        }

        guard !headers.isEmpty else { return nil }

        let body = lines[bodyStartIndex...].joined(separator: "\n")
        return (headers, body)
    }

    private static func extractFilename(from header: String) -> String? {
        let patterns = [
            "filename\\*=utf-8''([^;\\s]+)",
            "filename\\*=UTF-8''([^;\\s]+)",
            "filename=\"([^\"]+)\"",
            "filename=([^;\\s]+)",
            "name=\"([^\"]+)\"",
            "name=([^;\\s]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: header) {
                var fn = String(header[range])
                fn = fn.removingPercentEncoding ?? fn
                fn = decodeMimeFilename(fn)
                if !fn.isEmpty { return fn }
            }
        }
        return nil
    }

    private static func decodeMimeFilename(_ filename: String) -> String {
        var result = filename

        // =?charset?encoding?text?= Format (MIME encoded-word)
        if result.contains("=?") {
            // UTF-8 Quoted-Printable
            result = result.replacingOccurrences(of: "=?utf-8?Q?", with: "", options: .caseInsensitive)
            result = result.replacingOccurrences(of: "=?UTF-8?Q?", with: "", options: .caseInsensitive)
            result = result.replacingOccurrences(of: "=?iso-8859-1?Q?", with: "", options: .caseInsensitive)
            result = result.replacingOccurrences(of: "?=", with: "")
            result = result.replacingOccurrences(of: "_", with: " ")

            // =XX hex decode (Quoted-Printable)
            var decoded = ""
            var i = result.startIndex
            while i < result.endIndex {
                if result[i] == "=" && result.distance(from: i, to: result.endIndex) >= 3 {
                    let hexStart = result.index(after: i)
                    let hexEnd = result.index(hexStart, offsetBy: 2)
                    if let byte = UInt8(String(result[hexStart..<hexEnd]), radix: 16) {
                        decoded.append(Character(UnicodeScalar(byte)))
                        i = hexEnd
                        continue
                    }
                }
                decoded.append(result[i])
                i = result.index(after: i)
            }
            result = decoded
        }

        return result
    }

    private static func validatePDF(_ data: Data, indent: String) {
        // Check PDF header
        if let pdfStart = String(data: data.prefix(16), encoding: .ascii) {
            print("\(indent)📎 [PDF-CHECK] Start: '\(pdfStart)'")
        }

        // Check for %%EOF
        let hasEOF = data.suffix(1024).range(of: "%%EOF".data(using: .ascii)!) != nil
        print("\(indent)📎 [PDF-CHECK] Contains %%EOF: \(hasEOF)")

        // startxref Check
        if let startxrefData = "startxref".data(using: .ascii),
           let range = data.range(of: startxrefData) {
            let afterStartxref = data[range.upperBound...]
            if let endIdx = afterStartxref.firstIndex(where: { byte in
                let char = Character(UnicodeScalar(byte))
                return !char.isNumber && !char.isWhitespace
            }) {
                let numData = afterStartxref[..<endIdx]
                if let numStr = String(data: numData, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let startxref = Int(numStr) {
                    let valid = startxref < data.count
                    print("\(indent)📎 [PDF-CHECK] startxref=\(startxref), file_size=\(data.count), valid=\(valid)")
                }
            }
        }
    }
}
