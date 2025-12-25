// TechnicalHeaderParser.swift
// Parser für technische Email-Header und RAW-Ansicht

import Foundation

// MARK: - Technical Header Parser

class TechnicalHeaderParser {
    
    struct ParsedHeader {
        let name: String
        let value: String
        let isStandard: Bool
        let category: HeaderCategory
    }
    
    enum HeaderCategory {
        case routing      // From, To, CC, BCC
        case metadata     // Date, Message-ID, Subject
        case mime         // Content-Type, Content-Transfer-Encoding
        case transport    // Received, Return-Path
        case custom       // X-Headers
        case security     // DKIM, SPF, DMARC
    }
    
    // MARK: - Parse Headers from RAW
    
    func parseHeaders(from rawMessage: Data) -> [ParsedHeader] {
        guard let text = String(data: rawMessage, encoding: .utf8) else {
            return []
        }
        
        var headers: [ParsedHeader] = []
        var currentHeader: (name: String, value: String)?
        
        let lines = text.components(separatedBy: "\r\n")
        
        for line in lines {
            // Empty line marks end of headers
            if line.isEmpty {
                if let header = currentHeader {
                    headers.append(createParsedHeader(name: header.name, value: header.value))
                }
                break
            }
            
            // Check if line starts with whitespace (continuation)
            if line.starts(with: " ") || line.starts(with: "\t") {
                // Continuation of previous header
                if currentHeader != nil {
                    currentHeader!.value += " " + line.trimmingCharacters(in: .whitespaces)
                }
            } else {
                // New header
                if let header = currentHeader {
                    headers.append(createParsedHeader(name: header.name, value: header.value))
                }
                
                if let colonIndex = line.firstIndex(of: ":") {
                    let name = String(line[..<colonIndex])
                    let value = String(line[line.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    currentHeader = (name, value)
                }
            }
        }
        
        // Don't forget the last header
        if let header = currentHeader {
            headers.append(createParsedHeader(name: header.name, value: header.value))
        }
        
        return headers
    }
    
    // MARK: - Categorize Headers
    
    private func createParsedHeader(name: String, value: String) -> ParsedHeader {
        let category = categorizeHeader(name: name)
        let isStandard = isStandardHeader(name: name)
        
        // Decode encoded values if necessary
        let decodedValue = decodeEncodedWord(value)
        
        return ParsedHeader(
            name: name,
            value: decodedValue,
            isStandard: isStandard,
            category: category
        )
    }
    
    private func categorizeHeader(name: String) -> HeaderCategory {
        let lowerName = name.lowercased()
        
        switch lowerName {
        case "from", "to", "cc", "bcc", "reply-to":
            return .routing
        case "date", "message-id", "subject", "in-reply-to", "references":
            return .metadata
        case let n where n.starts(with: "content-"):
            return .mime
        case "received", "return-path", "delivered-to":
            return .transport
        case let n where n.starts(with: "x-"):
            return .custom
        case "dkim-signature", "authentication-results", "arc-seal":
            return .security
        default:
            return .metadata
        }
    }
    
    private func isStandardHeader(name: String) -> Bool {
        let standardHeaders = [
            "from", "to", "cc", "bcc", "subject", "date", "message-id",
            "in-reply-to", "references", "content-type", "content-transfer-encoding",
            "mime-version", "received", "return-path"
        ]
        return standardHeaders.contains(name.lowercased())
    }
    
    // MARK: - Decode RFC 2047 Encoded Words
    
    private func decodeEncodedWord(_ value: String) -> String {
        // Pattern: =?charset?encoding?encoded-text?=
        let pattern = #"=\?([^?]+)\?([BQ])\?([^?]+)\?="#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        
        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: value) else { continue }
            
            if let charsetRange = Range(match.range(at: 1), in: value),
               let encodingRange = Range(match.range(at: 2), in: value),
               let textRange = Range(match.range(at: 3), in: value) {
                
                let charset = String(value[charsetRange])
                let encoding = String(value[encodingRange]).uppercased()
                let encodedText = String(value[textRange])
                
                if let decoded = decodeText(encodedText, encoding: encoding, charset: charset) {
                    result.replaceSubrange(range, with: decoded)
                }
            }
        }
        
        return result
    }
    
    private func decodeText(_ text: String, encoding: String, charset: String) -> String? {
        switch encoding {
        case "B":
            // Base64
            guard let data = Data(base64Encoded: text) else { return nil }
            return String(data: data, encoding: encodingFromCharset(charset))
            
        case "Q":
            // Quoted-Printable
            return decodeQuotedPrintable(text, charset: charset)
            
        default:
            return nil
        }
    }
    
    private func decodeQuotedPrintable(_ text: String, charset: String) -> String? {
        var result = text.replacingOccurrences(of: "_", with: " ")
        
        // Decode =XX sequences
        let pattern = #"=([0-9A-F]{2})"#
        let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        
        for match in matches.reversed() {
            if let hexRange = Range(match.range(at: 1), in: result) {
                let hex = String(result[hexRange])
                if let byte = UInt8(hex, radix: 16) {
                    let char = String(Character(UnicodeScalar(byte)))
                    let fullRange = Range(match.range, in: result)!
                    result.replaceSubrange(fullRange, with: char)
                }
            }
        }
        
        // Convert to proper encoding
        if let data = result.data(using: .isoLatin1) {
            return String(data: data, encoding: encodingFromCharset(charset))
        }
        
        return result
    }
    
    private func encodingFromCharset(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "utf-8":
            return .utf8
        case "iso-8859-1", "latin1":
            return .isoLatin1
        case "iso-8859-15":
            return .isoLatin2
        case "windows-1252":
            return .windowsCP1252
        default:
            return .utf8
        }
    }
}

// MARK: - Technical View Formatter

extension TechnicalHeaderParser {
    
    /// Format headers for technical display
    func formatForDisplay(_ headers: [ParsedHeader]) -> String {
        var result = ""
        
        // Group by category
        let grouped = Dictionary(grouping: headers, by: { $0.category })
        
        let categoryOrder: [HeaderCategory] = [.routing, .metadata, .transport, .security, .mime, .custom]
        
        for category in categoryOrder {
            guard let categoryHeaders = grouped[category], !categoryHeaders.isEmpty else { continue }
            
            result += "--- \(categoryName(category)) ---\n"
            
            for header in categoryHeaders {
                let prefix = header.isStandard ? "" : "* "
                result += "\(prefix)\(header.name): \(header.value)\n"
            }
            
            result += "\n"
        }
        
        return result
    }
    
    private func categoryName(_ category: HeaderCategory) -> String {
        switch category {
        case .routing: return "ROUTING"
        case .metadata: return "METADATA"
        case .mime: return "MIME"
        case .transport: return "TRANSPORT"
        case .custom: return "CUSTOM"
        case .security: return "SECURITY"
        }
    }
}
