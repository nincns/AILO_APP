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
        var bodyStart = 0

        guard let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ([:], 0)
        }

        // ✅ Robuster Ansatz: Erst Header/Body-Grenze finden
        // Suche nach \r\n\r\n oder \n\n
        if let crlfRange = string.range(of: "\r\n\r\n") {
            bodyStart = string.distance(from: string.startIndex, to: crlfRange.upperBound)
            let headerString = String(string[..<crlfRange.lowerBound])
            headers = parseHeaderString(headerString)
            print("📎 [AttachmentExtractor] Found header/body boundary at CRLF, bodyStart: \(bodyStart)")
        } else if let lfRange = string.range(of: "\n\n") {
            bodyStart = string.distance(from: string.startIndex, to: lfRange.upperBound)
            let headerString = String(string[..<lfRange.lowerBound])
            headers = parseHeaderString(headerString)
            print("📎 [AttachmentExtractor] Found header/body boundary at LF, bodyStart: \(bodyStart)")
        } else {
            // Fallback: Suche erste Boundary-Zeile
            if let boundaryRange = string.range(of: "\n--", options: .literal) {
                // Headers gehen bis vor das \n
                let headerString = String(string[..<boundaryRange.lowerBound])
                headers = parseHeaderString(headerString)
                // Body startet beim --
                bodyStart = string.distance(from: string.startIndex, to: boundaryRange.lowerBound) + 1
                print("📎 [AttachmentExtractor] Found header/body boundary at first --, bodyStart: \(bodyStart)")
            }
        }

        return (headers, bodyStart)
    }

    /// Parst einen Header-String in ein Dictionary (mit RFC 5322 Folded Header Support)
    private static func parseHeaderString(_ headerString: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""

        let lines = headerString.components(separatedBy: "\n")

        for line in lines {
            // Entferne \r am Ende (für \r\n Line-Endings)
            let cleanLine = line.hasSuffix("\r") ? String(line.dropLast()) : line

            // ✅ RFC 5322: Folded Header (beginnt mit Whitespace oder Tab)
            if cleanLine.hasPrefix(" ") || cleanLine.hasPrefix("\t") {
                currentValue += " " + cleanLine.trimmingCharacters(in: .whitespaces)
                continue
            }

            // Neuer Header - vorherigen speichern
            if let key = currentKey, !currentValue.isEmpty {
                headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }

            // Header-Zeile parsen
            if let colonIndex = cleanLine.firstIndex(of: ":") {
                currentKey = String(cleanLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(cleanLine[cleanLine.index(after: colonIndex)...])
            }
        }

        // Letzten Header speichern
        if let key = currentKey, !currentValue.isEmpty {
            headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        return headers
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

        let boundaryMarker = "--" + boundary
        let closingMarker = "--" + boundary + "--"

        let lines = string.components(separatedBy: "\n")
        var parts: [[String]] = []
        var currentPart: [String] = []
        var inPart = false

        print("\(indent)📎 [AttachmentExtractor] Scanning \(lines.count) lines for boundary: \(boundaryMarker.prefix(50))...")

        for (lineIndex, line) in lines.enumerated() {
            // ✅ FIX: Robustere Boundary-Erkennung - entferne \r und trimme
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n\t "))

            // Closing Boundary zuerst prüfen (ist länger)
            if trimmed.hasPrefix(closingMarker) {
                print("\(indent)📎 [AttachmentExtractor] Found CLOSING boundary at line \(lineIndex)")
                if inPart && !currentPart.isEmpty {
                    parts.append(currentPart)
                }
                break
            }

            // Start-Boundary mit hasPrefix statt ==
            if trimmed.hasPrefix(boundaryMarker) {
                print("\(indent)📎 [AttachmentExtractor] Found boundary at line \(lineIndex)")
                if inPart && !currentPart.isEmpty {
                    parts.append(currentPart)
                    print("\(indent)📎 [AttachmentExtractor] Saved part with \(currentPart.count) lines")
                }
                currentPart = []
                inPart = true
                continue
            }

            // Content sammeln
            if inPart {
                currentPart.append(line)
            }
        }

        // Falls kein Closing Boundary gefunden
        if inPart && !currentPart.isEmpty {
            parts.append(currentPart)
            print("\(indent)📎 [AttachmentExtractor] Saved final part with \(currentPart.count) lines")
        }

        print("\(indent)📎 [AttachmentExtractor] Total parts found: \(parts.count)")

        for (index, partLines) in parts.enumerated() {
            print("\(indent)📎 [AttachmentExtractor] Processing part \(index + 1), lines: \(partLines.count)")

            // DEBUG: Erste Zeile anzeigen
            if let firstLine = partLines.first {
                print("\(indent)📎 [AttachmentExtractor] Part \(index + 1) starts with: '\(firstLine.prefix(60))'")
            }

            processPartLines(partLines, results: &results, depth: depth)
        }
    }

    private static func processPartLines(_ lines: [String], results: inout [ExtractedAttachment], depth: Int) {
        let indent = String(repeating: "  ", count: depth)

        guard !lines.isEmpty else {
            print("\(indent)📎 [AttachmentExtractor] Empty part, skipping")
            return
        }

        // Header/Body trennen mit RFC 5322 Folded Headers Support
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        var bodyStartLine = 0
        var foundEmptyLine = false

        for (index, line) in lines.enumerated() {
            // ✅ FIX: Robustere Leerzeilen-Erkennung
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Leerzeile = Ende der Part-Headers
            if trimmed.isEmpty {
                if let key = currentKey, !currentValue.isEmpty {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                bodyStartLine = index + 1
                foundEmptyLine = true
                break
            }

            // Entferne \r am Ende
            let cleanLine = line.hasSuffix("\r") ? String(line.dropLast()) : line

            // RFC 5322: Folded Header (beginnt mit Whitespace/Tab)
            if cleanLine.hasPrefix(" ") || cleanLine.hasPrefix("\t") {
                currentValue += " " + cleanLine.trimmingCharacters(in: .whitespaces)
                continue
            }

            // Vorherigen Header speichern
            if let key = currentKey, !currentValue.isEmpty {
                headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
            }

            // Neuen Header parsen
            if let colonIndex = cleanLine.firstIndex(of: ":") {
                currentKey = String(cleanLine[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(cleanLine[cleanLine.index(after: colonIndex)...])
            }
        }

        // Letzten Header speichern falls nicht durch Leerzeile beendet
        if let key = currentKey, !currentValue.isEmpty {
            headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        // ✅ FIX: Auch ohne Leerzeile weitermachen wenn Headers gefunden
        if !foundEmptyLine && !headers.isEmpty {
            print("\(indent)📎 [AttachmentExtractor] No empty line but found \(headers.count) headers")
            bodyStartLine = lines.count // Kein Body
        }

        guard !headers.isEmpty else {
            print("\(indent)📎 [AttachmentExtractor] No valid headers in part")
            return
        }

        print("\(indent)📎 [AttachmentExtractor] Parsed \(headers.count) headers")

        let contentType = headers["content-type"] ?? ""
        let encoding = headers["content-transfer-encoding"] ?? ""
        let disposition = headers["content-disposition"] ?? ""

        print("\(indent)📎 [AttachmentExtractor] Content-Type: \(contentType.prefix(60))...")

        // Body-Zeilen
        let bodyLines = bodyStartLine < lines.count ? Array(lines[bodyStartLine...]) : []
        let body = bodyLines.joined(separator: "\n")

        // Rekursiv bei verschachteltem Multipart
        if contentType.lowercased().contains("multipart/") {
            if let nestedBoundary = extractBoundary(from: contentType),
               let bodyData = body.data(using: .utf8) {
                print("\(indent)📎 [AttachmentExtractor] 🔁 Nested multipart with boundary: \(nestedBoundary.prefix(40))...")
                extractFromMultipart(bodyData[...], boundary: nestedBoundary, results: &results, depth: depth + 1)
            }
            return
        }

        // Attachment prüfen
        let lowerContentType = contentType.lowercased()
        let lowerDisposition = disposition.lowercased()

        let isAttachment = lowerDisposition.contains("attachment") ||
                          lowerContentType.contains("application/pdf") ||
                          lowerContentType.contains("application/") ||
                          (lowerContentType.contains("image/") && lowerDisposition.contains("attachment"))

        guard isAttachment else {
            print("\(indent)📎 [AttachmentExtractor] Not an attachment: \(contentType.prefix(40))")
            return
        }

        // Filename extrahieren
        let filename = extractFilename(from: disposition) ??
                      extractFilename(from: contentType) ??
                      "attachment_\(results.count + 1).bin"

        print("\(indent)📎 [AttachmentExtractor] 📎 Extracting: \(filename)")

        // Base64 dekodieren
        if encoding.lowercased().contains("base64") {
            let base64Lines = bodyLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("--") }

            let base64String = base64Lines.joined()
            print("\(indent)📎 [AttachmentExtractor] Base64 data: \(base64String.count) chars")

            if let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters),
               !data.isEmpty {

                // PDF-Integritätscheck
                if filename.lowercased().hasSuffix(".pdf") {
                    validatePDF(data, indent: indent)
                }

                let mimeType = contentType.components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? "application/octet-stream"

                results.append(ExtractedAttachment(
                    filename: filename,
                    mimeType: mimeType,
                    data: data,
                    contentId: headers["content-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                ))
                print("\(indent)📎 [AttachmentExtractor] ✅ Decoded: \(filename) (\(data.count) bytes)")
            } else {
                print("\(indent)❌ [AttachmentExtractor] Base64 decode failed for \(filename)")
            }
        } else {
            print("\(indent)📎 [AttachmentExtractor] Not Base64 encoded, skipping")
        }
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
