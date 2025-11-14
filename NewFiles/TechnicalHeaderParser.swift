// AILO_APP/Helpers/Parsers/TechnicalHeaderParser_Phase5.swift
// PHASE 5: Technical Header Parser
// Parses and displays email headers in technical view

import Foundation

// MARK: - Email Header

/// Parsed email header (single line)
public struct EmailHeader: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let value: String
    public let rawLine: String
    
    public init(name: String, value: String, rawLine: String) {
        self.name = name
        self.value = value
        self.rawLine = rawLine
    }
}

// MARK: - Technical Header Parser

/// Phase 5: Parser for technical email headers
public class TechnicalHeaderParser {
    
    // MARK: - Main Parsing
    
    /// Parse RAW RFC822 message into structured headers and body
    /// - Parameter rawMessage: Complete RFC822 message
    /// - Returns: Headers and body separately
    public static func parse(rawMessage: String) -> (headers: [EmailHeader], body: String) {
        let lines = rawMessage.components(separatedBy: "\n")
        
        var headers: [EmailHeader] = []
        var bodyStartIndex = 0
        var inHeader = true
        var currentHeaderName: String?
        var currentHeaderValue = ""
        var currentRawLine = ""
        
        for (index, line) in lines.enumerated() {
            // Empty line = end of headers
            if line.trimmingCharacters(in: .whitespaces).isEmpty && inHeader {
                // Save last header
                if let name = currentHeaderName, !currentHeaderValue.isEmpty {
                    headers.append(EmailHeader(
                        name: name,
                        value: currentHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        rawLine: currentRawLine
                    ))
                }
                
                inHeader = false
                bodyStartIndex = index + 1
                break
            }
            
            if inHeader {
                // Continuation line (starts with space/tab)
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    currentHeaderValue += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentRawLine += "\n" + line
                } else {
                    // New header line
                    
                    // Save previous header
                    if let name = currentHeaderName, !currentHeaderValue.isEmpty {
                        headers.append(EmailHeader(
                            name: name,
                            value: currentHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines),
                            rawLine: currentRawLine
                        ))
                    }
                    
                    // Parse new header
                    if let colonIndex = line.firstIndex(of: ":") {
                        currentHeaderName = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                        currentHeaderValue = String(line[line.index(after: colonIndex)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        currentRawLine = line
                    }
                }
            }
        }
        
        // Extract body
        let bodyLines = Array(lines[bodyStartIndex...])
        let body = bodyLines.joined(separator: "\n")
        
        return (headers, body)
    }
    
    /// Parse only headers (fast)
    /// - Parameter rawMessage: Complete RFC822 message
    /// - Returns: Parsed headers
    public static func parseHeaders(rawMessage: String) -> [EmailHeader] {
        let (headers, _) = parse(rawMessage: rawMessage)
        return headers
    }
    
    /// Get specific header value
    /// - Parameters:
    ///   - name: Header name (case-insensitive)
    ///   - headers: List of headers
    /// - Returns: First matching header value
    public static func getHeader(name: String, from headers: [EmailHeader]) -> String? {
        return headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }
    
    /// Get all headers with specific name (e.g., "Received")
    /// - Parameters:
    ///   - name: Header name (case-insensitive)
    ///   - headers: List of headers
    /// - Returns: All matching header values
    public static func getHeaders(name: String, from headers: [EmailHeader]) -> [String] {
        return headers
            .filter { $0.name.lowercased() == name.lowercased() }
            .map { $0.value }
    }
    
    // MARK: - Header Categories
    
    /// Categorize headers into groups for display
    /// - Parameter headers: List of headers
    /// - Returns: Categorized headers
    public static func categorize(headers: [EmailHeader]) -> [String: [EmailHeader]] {
        var categories: [String: [EmailHeader]] = [
            "Essential": [],
            "Routing": [],
            "Authentication": [],
            "Content": [],
            "Other": []
        ]
        
        for header in headers {
            let name = header.name.lowercased()
            
            switch name {
            // Essential
            case "from", "to", "cc", "bcc", "subject", "date", "message-id":
                categories["Essential"]?.append(header)
                
            // Routing
            case "received", "return-path", "delivered-to":
                categories["Routing"]?.append(header)
                
            // Authentication
            case "dkim-signature", "arc-authentication-results", "authentication-results",
                 "arc-message-signature", "arc-seal":
                categories["Authentication"]?.append(header)
                
            // Content
            case "content-type", "content-transfer-encoding", "mime-version",
                 "content-disposition", "content-id":
                categories["Content"]?.append(header)
                
            // Other
            default:
                categories["Other"]?.append(header)
            }
        }
        
        // Remove empty categories
        return categories.filter { !$0.value.isEmpty }
    }
    
    // MARK: - Header Formatting
    
    /// Format header for display (syntax highlighting)
    /// - Parameter header: Email header
    /// - Returns: Formatted header with name and value
    public static func format(header: EmailHeader) -> (name: String, value: String) {
        return (header.name, header.value)
    }
    
    /// Decode encoded-word headers (RFC 2047)
    /// Example: =?UTF-8?B?SGVsbG8gV29ybGQ=?= → Hello World
    /// - Parameter encodedValue: Encoded header value
    /// - Returns: Decoded value
    public static func decodeEncodedWord(_ encodedValue: String) -> String {
        // Pattern: =?charset?encoding?encoded-text?=
        let pattern = /=\?([^?]+)\?([BQbq])\?([^?]+)\?=/
        
        var result = encodedValue
        var matches: [(range: Range<String.Index>, charset: String, encoding: String, text: String)] = []
        
        // Find all encoded words
        for match in encodedValue.matches(of: pattern) {
            if let range = Range(match.range, in: encodedValue) {
                let charset = String(match.1)
                let encoding = String(match.2).uppercased()
                let text = String(match.3)
                
                matches.append((range, charset, encoding, text))
            }
        }
        
        // Decode in reverse order (to maintain ranges)
        for (range, charset, encoding, text) in matches.reversed() {
            var decoded = ""
            
            if encoding == "B" {
                // Base64
                if let data = Data(base64Encoded: text),
                   let string = String(data: data, encoding: .utf8) {
                    decoded = string
                }
            } else if encoding == "Q" {
                // Quoted-Printable
                decoded = decodeQuotedPrintableHeader(text)
            }
            
            result.replaceSubrange(range, with: decoded)
        }
        
        return result
    }
    
    /// Decode Quoted-Printable in headers (different from body QP)
    /// - Parameter text: QP-encoded text
    /// - Returns: Decoded text
    private static func decodeQuotedPrintableHeader(_ text: String) -> String {
        var result = ""
        var i = text.startIndex
        
        while i < text.endIndex {
            let char = text[i]
            
            if char == "=" && text.distance(from: i, to: text.endIndex) >= 3 {
                let nextIndex = text.index(after: i)
                let nextNextIndex = text.index(after: nextIndex)
                let hex = String(text[nextIndex..<text.index(after: nextNextIndex)])
                
                if let value = UInt8(hex, radix: 16) {
                    result.append(Character(UnicodeScalar(value)))
                    i = text.index(after: nextNextIndex)
                    continue
                }
            } else if char == "_" {
                // Underscore = space in header QP
                result.append(" ")
                i = text.index(after: i)
                continue
            }
            
            result.append(char)
            i = text.index(after: i)
        }
        
        return result
    }
}

// MARK: - Header Display Helpers

extension EmailHeader {
    
    /// Check if header is important (should be highlighted)
    public var isImportant: Bool {
        let important = ["from", "to", "cc", "subject", "date", "message-id"]
        return important.contains(name.lowercased())
    }
    
    /// Check if header is security-related
    public var isSecurityRelated: Bool {
        let security = ["dkim-signature", "authentication-results", "arc-authentication-results"]
        return security.contains(name.lowercased())
    }
    
    /// Check if header is routing-related
    public var isRoutingRelated: Bool {
        let routing = ["received", "return-path", "delivered-to"]
        return routing.contains(name.lowercased())
    }
}

// MARK: - Usage Documentation

/*
 TECHNICAL HEADER PARSER USAGE (Phase 5)
 ========================================
 
 PARSE COMPLETE MESSAGE:
 ```swift
 let (headers, body) = TechnicalHeaderParser.parse(rawMessage: rawRFC822)
 
 print("Headers: \(headers.count)")
 print("Body length: \(body.count) chars")
 ```
 
 PARSE HEADERS ONLY:
 ```swift
 let headers = TechnicalHeaderParser.parseHeaders(rawMessage: rawRFC822)
 
 for header in headers {
     print("\(header.name): \(header.value)")
 }
 ```
 
 GET SPECIFIC HEADER:
 ```swift
 if let subject = TechnicalHeaderParser.getHeader(name: "Subject", from: headers) {
     print("Subject: \(subject)")
 }
 
 // Get all "Received" headers (trace route)
 let received = TechnicalHeaderParser.getHeaders(name: "Received", from: headers)
 for hop in received {
     print("Hop: \(hop)")
 }
 ```
 
 CATEGORIZE HEADERS:
 ```swift
 let categories = TechnicalHeaderParser.categorize(headers: headers)
 
 for (category, headers) in categories {
     print("\n[\(category)]")
     for header in headers {
         print("  \(header.name): \(header.value)")
     }
 }
 ```
 
 DECODE ENCODED HEADERS:
 ```swift
 let encoded = "=?UTF-8?B?SGVsbG8gV29ybGQ=?="
 let decoded = TechnicalHeaderParser.decodeEncodedWord(encoded)
 print(decoded) // "Hello World"
 ```
 
 DISPLAY IN UI:
 ```swift
 ForEach(headers) { header in
     VStack(alignment: .leading) {
         Text(header.name)
             .font(.caption)
             .foregroundColor(header.isImportant ? .blue : .secondary)
         
         Text(header.value)
             .font(.system(.body, design: .monospaced))
     }
 }
 ```
 */
