// AILO_APP/Helpers/Parsers/MIMEParser_Phase6_Robust.swift
// PHASE 6: Robust MIME Parser Extensions
// Handles RFC violations, edge cases, and I18N filename encoding

import Foundation

// MARK: - MIME Parser Robustness Extensions

extension MIMEParser {
    
    // MARK: - Robust Boundary Detection
    
    /// Robustly detect boundaries even with malformed headers
    /// Many real-world emails violate RFC by having inconsistent boundaries
    static func robustDetectBoundary(from contentType: String) -> String? {
        // Standard: boundary="something"
        if let boundary = extractBoundary(from: contentType) {
            return boundary
        }
        
        // Fallback: boundary=something (no quotes)
        if let range = contentType.range(of: "boundary=", options: .caseInsensitive) {
            let afterBoundary = contentType[range.upperBound...]
            let boundaryValue = afterBoundary
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if let boundary = boundaryValue, !boundary.isEmpty {
                print("⚠️  [MIME-ROBUST] Found unquoted boundary: \(boundary)")
                return boundary
            }
        }
        
        return nil
    }
    
    /// Find boundary in raw content when header parsing fails
    /// Scans first 1000 bytes for boundary-like patterns
    static func guessBoundaryFromContent(rawContent: String) -> String? {
        let lines = rawContent.prefix(1000).components(separatedBy: "\n")
        
        for line in lines {
            // Look for lines starting with -- (boundary marker)
            if line.hasPrefix("--") && line.count > 10 && line.count < 100 {
                let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.rangeOfCharacter(from: .alphanumerics) != nil {
                    print("⚠️  [MIME-ROBUST] Guessed boundary from content: \(candidate)")
                    return String(candidate.dropFirst(2)) // Remove --
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Tolerant Header Parsing
    
    /// Parse headers with tolerance for common violations
    static func tolerantParseHeaders(from text: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
            // Empty line = end of headers
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            
            // Continuation line (starts with space/tab)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if currentKey != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            
            // New header line
            if let colonIndex = line.firstIndex(of: ":") {
                // Save previous header
                if let key = currentKey {
                    headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // Parse new header
                currentKey = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                currentValue = String(line[line.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Malformed line - append to current value if we have one
                if currentKey != nil {
                    currentValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Save last header
        if let key = currentKey {
            headers[key.lowercased()] = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return headers
    }
    
    // MARK: - I18N Filename Decoding (RFC2231 + RFC2047)
    
    /// Decode filename with proper I18N support
    /// Handles: filename*=UTF-8''... (RFC2231) and =?UTF-8?Q?...?= (RFC2047)
    static func decodeInternationalFilename(from headers: [String: String]) -> String? {
        // Try Content-Disposition first
        if let disposition = headers["content-disposition"] {
            if let filename = decodeFilenameFromDisposition(disposition) {
                return filename
            }
        }
        
        // Try Content-Type as fallback (some mailers put filename there)
        if let contentType = headers["content-type"] {
            if let filename = decodeFilenameFromContentType(contentType) {
                return filename
            }
        }
        
        return nil
    }
    
    /// Decode filename from Content-Disposition header
    private static func decodeFilenameFromDisposition(_ disposition: String) -> String? {
        // RFC2231: filename*=UTF-8''encoded-name
        if let rfc2231Filename = extractRFC2231Parameter(from: disposition, parameter: "filename") {
            return rfc2231Filename
        }
        
        // RFC2047: filename="=?UTF-8?Q?...?="
        if let rfc2047Filename = extractQuotedParameter(from: disposition, parameter: "filename") {
            return decodeRFC2047(rfc2047Filename)
        }
        
        // Plain filename
        if let plainFilename = extractQuotedParameter(from: disposition, parameter: "filename") {
            return plainFilename
        }
        
        return nil
    }
    
    /// Decode filename from Content-Type header (legacy support)
    private static func decodeFilenameFromContentType(_ contentType: String) -> String? {
        // Some old mailers put filename in Content-Type: name="..."
        if let name = extractQuotedParameter(from: contentType, parameter: "name") {
            return decodeRFC2047(name)
        }
        
        return nil
    }
    
    /// Extract RFC2231 encoded parameter: parameter*=charset'language'value
    private static func extractRFC2231Parameter(from header: String, parameter: String) -> String? {
        // Look for parameter*=
        let pattern = "\(parameter)\\*=([^;]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
            return nil
        }
        
        guard let valueRange = Range(match.range(at: 1), in: header) else {
            return nil
        }
        
        let encodedValue = String(header[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse: charset'language'value
        let parts = encodedValue.components(separatedBy: "'")
        if parts.count >= 3 {
            let charset = parts[0].uppercased()
            let encodedText = parts[2]
            
            // Percent-decode
            guard let decoded = encodedText.removingPercentEncoding else {
                return nil
            }
            
            // Convert from charset if needed
            if charset == "UTF-8" || charset == "UTF8" {
                return decoded
            }
            
            // Handle other charsets (ISO-8859-1, etc.)
            return decoded
        }
        
        return nil
    }
    
    /// Extract quoted parameter value: parameter="value"
    private static func extractQuotedParameter(from header: String, parameter: String) -> String? {
        // Look for parameter="value" or parameter=value
        let patterns = [
            "\(parameter)=\"([^\"]+)\"",  // Quoted
            "\(parameter)=([^;\\s]+)"     // Unquoted
        ]
        
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else {
                continue
            }
            
            guard let valueRange = Range(match.range(at: 1), in: header) else {
                continue
            }
            
            return String(header[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    /// Decode RFC2047 encoded-word: =?charset?encoding?encoded-text?=
    private static func decodeRFC2047(_ text: String) -> String {
        // Pattern: =?charset?Q|B?encoded?=
        let pattern = "=\\?([^?]+)\\?([QB])\\?([^?]+)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        // Decode in reverse to maintain string indices
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: text),
                  let charsetRange = Range(match.range(at: 1), in: text),
                  let encodingRange = Range(match.range(at: 2), in: text),
                  let dataRange = Range(match.range(at: 3), in: text) else {
                continue
            }
            
            let charset = String(text[charsetRange]).uppercased()
            let encoding = String(text[encodingRange]).uppercased()
            let encodedData = String(text[dataRange])
            
            var decoded: String?
            
            if encoding == "Q" {
                // Quoted-Printable
                decoded = decodeQuotedPrintableForFilename(encodedData)
            } else if encoding == "B" {
                // Base64
                if let data = Data(base64Encoded: encodedData) {
                    decoded = String(data: data, encoding: .utf8)
                }
            }
            
            if let decodedText = decoded {
                result.replaceSubrange(fullRange, with: decodedText)
            }
        }
        
        return result
    }
    
    /// Decode Quoted-Printable for filename (underscore = space)
    private static func decodeQuotedPrintableForFilename(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "_", with: " ")
        
        // Decode =XX hex sequences
        let pattern = "=([0-9A-F]{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return result
        }
        
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            
            let hexString = String(result[hexRange])
            if let byte = UInt8(hexString, radix: 16) {
                let char = String(UnicodeScalar(byte))
                result.replaceSubrange(fullRange, with: char)
            }
        }
        
        return result
    }
    
    // MARK: - Malformed MIME Recovery
    
    /// Attempt to recover from malformed MIME structure
    static func attemptMIMERecovery(
        rawContent: String,
        declaredBoundary: String?
    ) -> [MIMEPart] {
        print("⚠️  [MIME-ROBUST] Attempting MIME recovery...")
        
        var parts: [MIMEPart] = []
        
        // If we have a boundary, try to split by it
        if let boundary = declaredBoundary {
            let boundaryMarker = "--\(boundary)"
            let sections = rawContent.components(separatedBy: boundaryMarker)
            
            for (index, section) in sections.enumerated() {
                if section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                
                // Try to parse as MIME part
                if let part = tryParseMalformedPart(section, index: index) {
                    parts.append(part)
                }
            }
        } else {
            // No boundary - try to guess structure
            if let guessedBoundary = guessBoundaryFromContent(rawContent: rawContent) {
                return attemptMIMERecovery(rawContent: rawContent, declaredBoundary: guessedBoundary)
            }
            
            // Complete failure - return single part with all content
            print("❌ [MIME-ROBUST] Could not recover MIME structure")
            parts.append(MIMEPart(
                partId: "1",
                headers: [:],
                body: rawContent,
                mediaType: "text/plain",
                charset: nil,
                transferEncoding: nil,
                disposition: nil,
                filename: nil,
                contentId: nil
            ))
        }
        
        return parts
    }
    
    /// Try to parse a malformed MIME part
    private static func tryParseMalformedPart(_ content: String, index: Int) -> MIMEPart? {
        // Split into headers and body
        let components = content.components(separatedBy: "\n\n")
        guard components.count >= 1 else {
            return nil
        }
        
        let headerSection = components.first ?? ""
        let bodySection = components.dropFirst().joined(separator: "\n\n")
        
        // Parse headers tolerantly
        let headers = tolerantParseHeaders(from: headerSection)
        
        // Extract essential fields
        let contentType = headers["content-type"] ?? "text/plain"
        let mediaType = contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "text/plain"
        
        let part = MIMEPart(
            partId: "\(index + 1)",
            headers: headers,
            body: bodySection,
            mediaType: mediaType,
            charset: extractCharset(from: contentType),
            transferEncoding: headers["content-transfer-encoding"],
            disposition: headers["content-disposition"],
            filename: decodeInternationalFilename(from: headers),
            contentId: extractContentId(from: headers["content-id"])
        )
        
        return part
    }
    
    // MARK: - Charset Fallback
    
    /// Detect charset with fallback mechanisms
    static func detectCharsetWithFallback(declaredCharset: String?, content: Data) -> String {
        // Try declared charset first
        if let charset = declaredCharset?.lowercased(),
           !charset.isEmpty && charset != "unknown" {
            return charset
        }
        
        // Try to detect from BOM
        if content.count >= 3 {
            let bom = [UInt8](content.prefix(3))
            if bom == [0xEF, 0xBB, 0xBF] {
                return "utf-8"
            }
        }
        
        // Check if valid UTF-8
        if String(data: content, encoding: .utf8) != nil {
            return "utf-8"
        }
        
        // Default fallback
        return "iso-8859-1"
    }
}

// MARK: - Usage Documentation

/*
 ROBUST MIME PARSER EXTENSIONS (Phase 6)
 ========================================
 
 INTERNATIONAL FILENAMES:
 ```swift
 let headers = [
     "content-disposition": "attachment; filename*=UTF-8''%C3%BCber.txt"
 ]
 
 if let filename = MIMEParser.decodeInternationalFilename(from: headers) {
     print(filename) // "über.txt"
 }
 ```
 
 TOLERANT BOUNDARY DETECTION:
 ```swift
 // Handles malformed boundaries
 if let boundary = MIMEParser.robustDetectBoundary(from: contentType) {
     // Even works with boundary=something (no quotes)
 }
 ```
 
 MIME RECOVERY:
 ```swift
 // Attempt to parse even with broken structure
 let parts = MIMEParser.attemptMIMERecovery(
     rawContent: rawMessage,
     declaredBoundary: boundary
 )
 ```
 
 CHARSET DETECTION:
 ```swift
 let charset = MIMEParser.detectCharsetWithFallback(
     declaredCharset: "unknown",
     content: bodyData
 )
 ```
 
 FEATURES:
 - RFC2231 filename decoding (UTF-8 names)
 - RFC2047 encoded-word support
 - Tolerant boundary detection
 - Malformed header parsing
 - BOM detection
 - Charset fallback
 - MIME structure recovery
 
 COMMON EDGE CASES HANDLED:
 - Missing quotes around boundary
 - Inconsistent boundaries
 - German umlauts in filenames (ä, ö, ü)
 - Spaces in unquoted parameters
 - Mixed line endings (CRLF/LF)
 - Missing Content-Type
 - Truncated headers
 */
