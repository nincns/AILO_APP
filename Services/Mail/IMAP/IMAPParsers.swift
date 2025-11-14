// AILO_APP/Configuration/Services/Mail/IMAPParsers.swift
// Parser utilities for IMAP protocol responses (ENVELOPE, FLAGS, INTERNALDATE, UID, BODYSTRUCTURE).
// Converts raw response lines into strongly typed structs (EnvelopeRecord, FlagsRecord, etc.).
// Focused purely on text parsing; independent of UI or networking.
// NOTE: Designed to be resilient against extra whitespace, different server variants, and literals already materialized by the transport layer.

import Foundation

public enum IMAPParseError: Error {
    case invalid(String)
}

// MARK: - Data Models

public struct EnvelopeRecord {
    public let uid: String
    public let subject: String
    public let from: String
    public let internalDate: Date?
}

public struct FlagsRecord {
    public let uid: String
    public let flags: [String]
}

// MARK: - New high-level models

public struct MessageEnvelope: Sendable, Equatable {
    public var subject: String?
    public var from: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var date: Date?
    public var messageId: String?

    public init(subject: String? = nil, from: String? = nil, to: [String] = [], cc: [String] = [], bcc: [String] = [], date: Date? = nil, messageId: String? = nil) {
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.messageId = messageId
    }
}

public struct FolderInfo: Sendable, Equatable {
    public let attributes: [String]
    public let delimiter: String?
    public let name: String
}

public enum IMAPBodyStructure: Sendable, Equatable {
    case single(Part)
    case multipart(type: String, subType: String, parts: [IMAPBodyStructure])

    public struct Part: Sendable, Equatable {
        public let partId: String?
        public let type: String
        public let subType: String
        public let params: [String: String]
        public let size: Int?
        public let disposition: String?
        public let filename: String?

        public init(partId: String? = nil, type: String, subType: String, params: [String: String] = [:], size: Int? = nil, disposition: String? = nil, filename: String? = nil) {
            self.partId = partId
            self.type = type
            self.subType = subType
            self.params = params
            self.size = size
            self.disposition = disposition
            self.filename = filename
        }
    }
}

public struct FetchResult: Sendable {
    public let uid: String?
    public let flags: [String]
    public let internalDate: Date?
    public let envelope: MessageEnvelope?
    public let bodySection: Data?
    public let bodyStructure: IMAPBodyStructure?
}

// MARK: - Public API

public struct IMAPParsers {
    public init() {}

    // ENVELOPE + INTERNALDATE + FLAGS block from UID FETCH
    // Returns one EnvelopeRecord per UID observed in the lines.
    public func parseEnvelope(_ lines: [String]) -> [EnvelopeRecord] {
        var result: [EnvelopeRecord] = []
        for raw in lines {
            guard raw.hasPrefix("* ") && raw.contains(" FETCH ") else { continue }
            guard let uid = extractUID(fromFetchLine: raw) else { continue }

            // Subject with RFC2047 decoding
            let rawSubject = extractEnvelopeSubject(from: raw) ?? ""
            let subject = RFC2047EncodedWordsParser.decodeSubject(rawSubject)
            if !rawSubject.isEmpty && rawSubject != subject {
                print("📧 Subject decoded: '\(rawSubject)' → '\(subject)'")
            }

            // From with RFC2047 decoding
            let rawFrom = extractEnvelopeFrom(from: raw) ?? ""
            let from = RFC2047EncodedWordsParser.decodeFrom(rawFrom)
            if !rawFrom.isEmpty && rawFrom != from {
                print("📧 From decoded: '\(rawFrom)' → '\(from)'")
            }

            // InternalDate
            let date = extractInternalDate(from: raw)

            result.append(EnvelopeRecord(uid: uid, subject: subject, from: from, internalDate: date))
        }
        return result
    }

    // FLAGS from UID FETCH
    public func parseFlags(_ lines: [String]) -> [FlagsRecord] {
        var result: [FlagsRecord] = []
        for raw in lines {
            guard raw.hasPrefix("* ") && raw.contains(" FETCH ") else { continue }
            guard let uid = extractUID(fromFetchLine: raw) else { continue }
            guard let flags = extractFlags(fromFetchLine: raw) else { continue }
            result.append(FlagsRecord(uid: uid, flags: flags))
        }
        return result
    }

    // Extract a Date from an INTERNALDATE "..." field in a single FETCH line
    public func parseInternalDate(_ line: String) -> Date? {
        return extractInternalDate(from: line)
    }

    // Extract UIDs from a single "* SEARCH ..." line
    public func parseUIDs(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("* SEARCH ") else { return [] }
        let rest = trimmed.dropFirst(9)
        return rest.split(whereSeparator: \.isWhitespace).map { String($0) }
    }

    // BODY[] and snippet helpers (returns raw body sections as strings)
    // For simplicity, this returns the body text if found inline on the lines collection.
    public func parseBodySection(_ lines: [String]) -> String? {
        // Heuristic: some servers include a literal body right after a line with "BODY[" or "BODY[]"
        // Our transport should have already read the literal bytes, so they appear concatenated in lines.
        // Try to join lines that do not look like tagged responses.
        let bodyCandidates = lines.filter { !$0.hasPrefix("A") && !$0.hasPrefix("* ") }
        if bodyCandidates.isEmpty {
            // Fallback: try everything after "BODY[" marker on the same line (rare)
            for l in lines {
                if let range = l.range(of: "BODY[") ?? l.range(of: "BODY[]") {
                    let tail = l[range.upperBound...]
                    if !tail.isEmpty { return String(tail) }
                }
            }
            return nil
        }
        // Join candidates with newlines
        return bodyCandidates.joined(separator: "\n")
    }

    // MARK: - New public parsing API

    /// Parse a full FETCH response data blob into a typed result.
    /// Tolerant to missing fields; throws on completely invalid input.
    public func parseFetchResponse(_ data: Data) throws -> FetchResult {
        guard !data.isEmpty else { throw IMAPParseError.invalid("Empty FETCH response") }
        // Attempt UTF-8, fallback to ISO-8859-1 for robustness
        let text = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
        guard !text.isEmpty else { throw IMAPParseError.invalid("FETCH response not decodable") }
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let fetchLine = lines.first(where: { $0.hasPrefix("* ") && $0.contains(" FETCH ") }) else {
            // Some servers might send tag on the same line; still try to extract basics
            if let any = lines.first { return FetchResult(uid: extractUID(fromFetchLine: any), flags: extractFlags(fromFetchLine: any) ?? [], internalDate: extractInternalDate(from: any), envelope: try? parseEnvelope(any), bodySection: extractLiteralBody(fromData: data, headerText: text), bodyStructure: (try? parseBodyStructure(any))) }
            throw IMAPParseError.invalid("No FETCH line found")
        }
        let uid = extractUID(fromFetchLine: fetchLine)
        let flags = extractFlags(fromFetchLine: fetchLine) ?? []
        let idate = extractInternalDate(from: fetchLine)
        let env = try? parseEnvelope(fetchLine)
        let bs = try? parseBodyStructure(fetchLine)
        let body = extractLiteralBody(fromData: data, headerText: text)
        return FetchResult(uid: uid, flags: flags, internalDate: idate, envelope: env, bodySection: body, bodyStructure: bs)
    }

    /// Parse an ENVELOPE (...) fragment from a single FETCH line.
    public func parseEnvelope(_ line: String) throws -> MessageEnvelope {
        // Subject with RFC2047 decoding
        let rawSubject = extractEnvelopeSubject(from: line)
        let subject = rawSubject != nil ? RFC2047EncodedWordsParser.decodeSubject(rawSubject!) : nil
        if let raw = rawSubject, let decoded = subject, raw != decoded {
            print("📧 Subject decoded: '\(raw)' → '\(decoded)'")
        }
        
        // From with RFC2047 decoding
        let rawFrom = extractEnvelopeFrom(from: line)
        let from = rawFrom != nil ? RFC2047EncodedWordsParser.decodeFrom(rawFrom!) : nil
        if let raw = rawFrom, let decoded = from, raw != decoded {
            print("📧 From decoded: '\(raw)' → '\(decoded)'")
        }
        
        // Date (INTERNALDATE is usually outside envelope, but try to parse if present)
        let date = extractInternalDate(from: line)
        // The full address lists are complex; keep tolerant and return minimal info for now.
        return MessageEnvelope(subject: subject, from: from, to: [], cc: [], bcc: [], date: date, messageId: nil)
    }

    /// Parse BODYSTRUCTURE from a single FETCH line. Produces a lightweight recursive structure.
    public func parseBodyStructure(_ line: String) throws -> IMAPBodyStructure {
        guard let range = line.range(of: "BODYSTRUCTURE ") ?? line.range(of: " BODY ") else {
            throw IMAPParseError.invalid("BODYSTRUCTURE not found")
        }
        // Capture from the opening parenthesis after BODYSTRUCTURE / BODY
        guard let open = line[range.upperBound...].firstIndex(of: "(") else {
            throw IMAPParseError.invalid("BODYSTRUCTURE missing opening bracket")
        }
        let payload = String(line[open...])
        let tokens = tokenizeBalanced(parenthesized: payload)
        guard !tokens.isEmpty else { throw IMAPParseError.invalid("BODYSTRUCTURE tokenization failed") }
        // If first token is a list, likely multipart. Otherwise, single-part.
        if case .list(let list) = tokens[0] {
            // Try to parse multipart: ( part part ... ) "subtype"
            var parts: [IMAPBodyStructure] = []
            for item in list {
                if case .list = item {
                    if let p = decodeSinglePart(from: item, defaultPartId: nil) {
                        parts.append(.single(p))
                    } else if let nested = try? decodeAsBodyStructure(item) {
                        parts.append(nested)
                    }
                }
            }
            // subtype appears after the list according to RFC (simplified heuristic)
            let subtype: String = {
                if tokens.count >= 2, case .atomOrString(let s) = tokens[1] { return s.uppercased() }
                return "MIXED"
            }()
            return .multipart(type: "MULTIPART", subType: subtype, parts: parts)
        } else {
            // Single-part root beginning directly with quoted type
            if let part = decodeSinglePart(from: tokens[0], defaultPartId: "1") {
                return .single(part)
            }
            throw IMAPParseError.invalid("Unable to parse single-part BODYSTRUCTURE")
        }
    }

    /// Parse a single LIST/LSUB line into FolderInfo
    public func parseListResponse(_ line: String) throws -> FolderInfo {
        // Example: * LIST (\HasNoChildren \Sent) "/" "Sent Items"
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("* ") && (trimmed.contains(" LIST ") || trimmed.contains(" LSUB ")) else {
            throw IMAPParseError.invalid("Not a LIST/LSUB line")
        }
        // Attributes
        var attrs: [String] = []
        if let r = trimmed.range(of: "(") , let end = trimmed[r.lowerBound...].firstIndex(of: ")") {
            let raw = trimmed[trimmed.index(after: r.lowerBound)..<end]
            attrs = raw.split(whereSeparator: \.isWhitespace).map { String($0) }
        }
        // Delimiter (may be NIL)
        var delimiter: String? = nil
        if let afterAttrs = trimmed.range(of: ") ") {
            let tail = trimmed[afterAttrs.upperBound...]
            if tail.hasPrefix("\""), let q2 = tail.dropFirst().firstIndex(of: "\"") {
                delimiter = String(tail[tail.index(after: tail.startIndex)..<q2])
            } else if tail.uppercased().hasPrefix("NIL") {
                delimiter = nil
            }
        }
        // Name: prefer last quoted segment
        let name: String = {
            if let lastQuoted = trimmed.split(separator: "\"", omittingEmptySubsequences: false).last {
                let s = String(lastQuoted).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { return s }
            }
            // Fallback: last whitespace token
            let fallback = trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        return FolderInfo(attributes: attrs, delimiter: delimiter, name: name)
    }

    // ✅ NEU: PHASE 2 - BODYSTRUCTURE Parser für Attachment-Erkennung
    public func hasAttachmentsFromBodyStructure(_ line: String) -> Bool {
        guard let range = line.range(of: "BODYSTRUCTURE ") else { return false }
        let payload = String(line[range.upperBound...])
        
        // Check für attachment oder mixed content types
        let lowercasePayload = payload.lowercased()
        return lowercasePayload.contains("\"attachment\"") || 
               lowercasePayload.contains("multipart/mixed") ||
               lowercasePayload.contains("application/") ||
               lowercasePayload.contains("image/") && lowercasePayload.contains("\"attachment\"")
    }

    
    public func extractUID(fromFetchLine line: String) -> String? {
        // Extract UID from FETCH response line like: "* 1 FETCH (UID 123 ...)"
        guard line.contains(" FETCH ") else { return nil }
        
        if let range = line.range(of: "UID ") {
            let afterUID = String(line[range.upperBound...])
            let components = afterUID.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
            return components.first.map(String.init)
        }
        
        return nil
    }
}

// MARK: - Phase 2 Extensions: Enhanced BodyStructure Types

/// Enhanced BODYSTRUCTURE with full section tracking
public struct EnhancedBodyStructure: Sendable {
    public let structure: IMAPBodyStructure
    public let sections: [SectionInfo]
    public let bodyCandidates: [SectionInfo]
    public let inlineParts: [SectionInfo]
    public let attachments: [SectionInfo]
    
    public init(structure: IMAPBodyStructure) {
        self.structure = structure
        
        // Analyze structure and extract metadata
        var allSections: [SectionInfo] = []
        var bodies: [SectionInfo] = []
        var inlines: [SectionInfo] = []
        var attachments: [SectionInfo] = []
        
        Self.analyzeStructure(structure, parentPath: "", 
                            sections: &allSections, 
                            bodies: &bodies, 
                            inlines: &inlines, 
                            attachments: &attachments)
        
        self.sections = allSections
        self.bodyCandidates = bodies
        self.inlineParts = inlines
        self.attachments = attachments
    }
    
    // MARK: - Analysis
    
    private static func analyzeStructure(_ structure: IMAPBodyStructure, 
                                        parentPath: String,
                                        sections: inout [SectionInfo],
                                        bodies: inout [SectionInfo],
                                        inlines: inout [SectionInfo],
                                        attachments: inout [SectionInfo]) {
        switch structure {
        case .single(let part):
            let sectionId = part.partId ?? (parentPath.isEmpty ? "1" : parentPath)
            let fullType = "\(part.type)/\(part.subType)".lowercased()
            
            let info = SectionInfo(
                sectionId: sectionId,
                mediaType: fullType,
                disposition: part.disposition,
                filename: part.filename,
                contentId: nil, // Not available in basic BODYSTRUCTURE
                size: part.size,
                isBodyCandidate: Self.isBodyCandidate(type: part.type, subType: part.subType)
            )
            
            sections.append(info)
            
            // Categorize
            if info.isBodyCandidate {
                bodies.append(info)
            }
            
            if part.disposition?.lowercased() == "inline" || 
               (part.disposition == nil && fullType.hasPrefix("image/")) {
                inlines.append(info)
            }
            
            if part.disposition?.lowercased() == "attachment" {
                attachments.append(info)
            }
            
        case .multipart(_, _, let parts):
            for (index, subPart) in parts.enumerated() {
                let subPath = parentPath.isEmpty ? "\(index + 1)" : "\(parentPath).\(index + 1)"
                analyzeStructure(subPart, parentPath: subPath, 
                               sections: &sections, bodies: &bodies, 
                               inlines: &inlines, attachments: &attachments)
            }
        }
    }
    
    private static func isBodyCandidate(type: String, subType: String) -> Bool {
        let normalized = "\(type)/\(subType)".lowercased()
        return normalized == "text/html" || normalized == "text/plain"
    }
}

/// Section information extracted from BODYSTRUCTURE
public struct SectionInfo: Sendable, Identifiable {
    public let sectionId: String         // IMAP section (e.g. "1.2")
    public let mediaType: String         // e.g. "text/html"
    public let disposition: String?      // "inline", "attachment", or nil
    public let filename: String?         // From Content-Disposition
    public let contentId: String?        // For cid: references (if available)
    public let size: Int?                // Size in bytes
    public let isBodyCandidate: Bool     // true for text/html, text/plain
    
    public var id: String { sectionId }
    
    public init(sectionId: String, mediaType: String, disposition: String? = nil,
                filename: String? = nil, contentId: String? = nil, size: Int? = nil,
                isBodyCandidate: Bool = false) {
        self.sectionId = sectionId
        self.mediaType = mediaType
        self.disposition = disposition
        self.filename = filename
        self.contentId = contentId
        self.size = size
        self.isBodyCandidate = isBodyCandidate
    }
}

// MARK: - IMAPParsers Phase 2 Extension

extension IMAPParsers {
    
    /// Parse BODYSTRUCTURE with full section analysis
    /// This is the Phase 2 entry point for structure parsing
    /// - Parameter lines: Raw FETCH response lines
    /// - Returns: Enhanced structure with section metadata
    public func parseEnhancedBodyStructure(_ lines: [String]) throws -> EnhancedBodyStructure? {
        // Find FETCH line with BODYSTRUCTURE
        guard let fetchLine = lines.first(where: { 
            $0.contains(" FETCH ") && $0.contains("BODYSTRUCTURE") 
        }) else {
            return nil
        }
        
        // Parse basic structure (existing method)
        let basicStructure = try parseBodyStructure(fetchLine)
        
        // Enhance with section analysis
        return EnhancedBodyStructure(structure: basicStructure)
    }
    
    /// Parse multiple BODYSTRUCTURE responses from batch fetch
    /// - Parameter lines: Raw FETCH response lines for multiple messages
    /// - Returns: Dictionary of UID -> EnhancedBodyStructure
    public func parseEnhancedBodyStructures(_ lines: [String]) throws -> [String: EnhancedBodyStructure] {
        var results: [String: EnhancedBodyStructure] = [:]
        
        // Group lines by FETCH response
        var currentUID: String?
        var currentLines: [String] = []
        
        for line in lines {
            if line.hasPrefix("* ") && line.contains(" FETCH ") {
                // New FETCH - process previous if exists
                if let uid = currentUID, !currentLines.isEmpty {
                    if let structure = try? parseEnhancedBodyStructure(currentLines) {
                        results[uid] = structure
                    }
                }
                
                // Extract UID from this line
                currentUID = extractUID(fromFetchLine: line)
                currentLines = [line]
            } else if !line.hasPrefix("A") && !line.hasPrefix("* OK") {
                // Continuation of current FETCH
                currentLines.append(line)
            }
        }
        
        // Process last FETCH
        if let uid = currentUID, !currentLines.isEmpty {
            if let structure = try? parseEnhancedBodyStructure(currentLines) {
                results[uid] = structure
            }
        }
        
        return results
    }
    
    /// Parse section content from FETCH response
    /// - Parameters:
    ///   - lines: Raw FETCH response
    ///   - sectionId: Expected section ID
    /// - Returns: Decoded section content
    public func parseSectionContent(_ lines: [String], sectionId: String) -> Data? {
        // Find line with section marker
        guard let bodyLine = lines.first(where: { 
            $0.contains("BODY[\(sectionId)]") || $0.contains("BODY.PEEK[\(sectionId)]")
        }) else {
            return nil
        }
        
        // Extract literal content
        return extractLiteralContent(from: lines, startingAt: bodyLine)
    }
    
    /// Parse multiple sections from multi-section FETCH response
    /// - Parameter lines: Raw FETCH response with multiple BODY[] parts
    /// - Returns: Dictionary of sectionId -> Data
    public func parseMultipleSections(_ lines: [String]) -> [String: Data] {
        var results: [String: Data] = []
        
        // Pattern: BODY[section] {size}
        let pattern = /BODY(?:\.PEEK)?\[([^\]]+)\]\s*\{(\d+)\}/
        
        var currentIndex = 0
        let joinedLines = lines.joined(separator: "\n")
        
        while currentIndex < joinedLines.count {
            let searchRange = joinedLines.index(joinedLines.startIndex, offsetBy: currentIndex)..<joinedLines.endIndex
            
            if let match = joinedLines[searchRange].firstMatch(of: pattern) {
                let sectionId = String(match.1)
                guard let size = Int(match.2) else { continue }
                
                // Find start of literal content (after "}\r\n")
                let matchEnd = match.range.upperBound
                guard let contentStart = joinedLines[matchEnd...].firstIndex(where: { $0 == "\n" }) else { break }
                
                let dataStart = joinedLines.index(after: contentStart)
                let dataEnd = joinedLines.index(dataStart, offsetBy: size, limitedBy: joinedLines.endIndex) ?? joinedLines.endIndex
                
                let content = String(joinedLines[dataStart..<dataEnd])
                results[sectionId] = Data(content.utf8)
                
                currentIndex = joinedLines.distance(from: joinedLines.startIndex, to: dataEnd)
            } else {
                break
            }
        }
        
        return results
    }
    
    // MARK: - Private Helpers
    
    private func extractLiteralContent(from lines: [String], startingAt markerLine: String) -> Data? {
        // Look for {n} literal size indicator
        guard let sizeRange = markerLine.range(of: #"\{(\d+)\}"#, options: .regularExpression),
              let sizeStr = markerLine[sizeRange].dropFirst().dropLast().split(separator: "{").last,
              let size = Int(sizeStr) else {
            return nil
        }
        
        // Literal content follows on next lines
        let markerIndex = lines.firstIndex { $0.contains(markerLine) } ?? 0
        let contentLines = lines.dropFirst(markerIndex + 1)
        
        let joined = contentLines.joined(separator: "\n")
        let data = Data(joined.utf8)
        
        // Truncate to expected size
        return data.prefix(size)
    }
}

// MARK: - Conversion to Phase 1 Entities

extension EnhancedBodyStructure {
    
    /// Convert to Phase 1 MIME parts entities
    /// - Parameter messageId: Message UUID
    /// - Returns: Array of MimePartEntity ready for storage
    public func toMimePartEntities(messageId: UUID) -> [MimePartEntity] {
        return sections.map { section in
            // Parse media type
            let components = section.mediaType.split(separator: "/")
            let type = components.first.map(String.init) ?? "application"
            let subType = components.dropFirst().first.map(String.init) ?? "octet-stream"
            
            return MimePartEntity(
                messageId: messageId,
                partId: section.sectionId,
                parentPartId: nil, // Will be set by parser
                mediaType: section.mediaType,
                charset: nil, // Will be extracted from MIME headers
                transferEncoding: nil, // Will be extracted from MIME headers
                disposition: section.disposition,
                filenameOriginal: section.filename,
                filenameNormalized: section.filename?.sanitizedFilename(),
                contentId: section.contentId,
                contentMd5: nil,
                contentSha256: nil, // Will be calculated when storing blob
                sizeOctets: section.size,
                bytesStored: nil,
                isBodyCandidate: section.isBodyCandidate,
                blobId: nil // Will be set when storing content
            )
        }
    }
}

// MARK: - String Extension

private extension String {
    /// Sanitize filename for safe storage
    func sanitizedFilename() -> String {
        // Remove path components
        let basename = (self as NSString).lastPathComponent
        
        // Remove dangerous characters
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-_ "))
        
        let sanitized = basename.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
        
        return sanitized.isEmpty ? "attachment" : sanitized
    }
}

// MARK: - New helpers for complex parsing

private enum IMAPToken {
    case atomOrString(String)
    case list([IMAPToken])
}

/// Tokenize a parenthesized IMAP fragment into nested lists and strings/atoms.
private func tokenizeBalanced(parenthesized s: String) -> [IMAPToken] {
    var i = s.startIndex
    func parseList() -> IMAPToken? {
        guard i < s.endIndex, s[i] == "(" else { return nil }
        i = s.index(after: i)
        var items: [IMAPToken] = []
        while i < s.endIndex {
            skipSpaces()
            if i < s.endIndex, s[i] == ")" { i = s.index(after: i); break }
            if i < s.endIndex, s[i] == "(" {
                if let sub = parseList() { items.append(sub) }
                continue
            }
            if let str = parseQuoted() { items.append(.atomOrString(str)) ; continue }
            let atom = parseAtom()
            if !atom.isEmpty { items.append(.atomOrString(atom)) } else { break }
        }
        return .list(items)
    }
    func parseQuoted() -> String? {
        guard i < s.endIndex, s[i] == "\"" else { return nil }
        i = s.index(after: i)
        var out = ""
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\" {
                i = s.index(after: i)
                if i < s.endIndex { out.append(s[i]); i = s.index(after: i) }
                continue
            }
            if ch == "\"" { i = s.index(after: i); break }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }
    func parseAtom() -> String {
        var out = ""
        while i < s.endIndex {
            let ch = s[i]
            if ch == "(" || ch == ")" || ch == " " || ch == "\t" { break }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }
    func skipSpaces() { while i < s.endIndex && (s[i] == " " || s[i] == "\t") { i = s.index(after: i) } }

    var tokens: [IMAPToken] = []
    while i < s.endIndex {
        if s[i] == "(" { if let l = parseList() { tokens.append(l) } ; continue }
        if let q = parseQuoted() { tokens.append(.atomOrString(q)); continue }
        let atom = parseAtom(); if !atom.isEmpty { tokens.append(.atomOrString(atom)) } else { break }
    }
    return tokens
}

/// Decode a token as a BODYSTRUCTURE (multipart or single-part). Throws on failure.
private func decodeAsBodyStructure(_ tok: IMAPToken) throws -> IMAPBodyStructure {
    switch tok {
    case .list(let items):
        if items.isEmpty { throw IMAPParseError.invalid("Empty BODYSTRUCTURE list") }
        // Heuristic: multipart starts with subpart lists; single-part starts with type/subtype strings
        if case .list = items.first! {
            // Multipart: collect nested parts lists; subtype may be after the list
            var parts: [IMAPBodyStructure] = []
            for it in items {
                if case .list = it {
                    if let sp = decodeSinglePart(from: it, defaultPartId: nil) {
                        parts.append(.single(sp))
                    } else if let nested = try? decodeAsBodyStructure(it) {
                        parts.append(nested)
                    }
                }
            }
            var subtype = "MIXED"
            if items.count >= 2, case .atomOrString(let s) = items[1] { subtype = s.uppercased() }
            return .multipart(type: "MULTIPART", subType: subtype, parts: parts)
        } else {
            if let p = decodeSinglePart(from: .list(items), defaultPartId: "1") { return .single(p) }
            throw IMAPParseError.invalid("Invalid single-part BODYSTRUCTURE")
        }
    default:
        throw IMAPParseError.invalid("Unexpected BODYSTRUCTURE token kind")
    }
}

/// Decode a single-part from a list token ("type" "subtype" (params ...) ...)
private func decodeSinglePart(from tok: IMAPToken, defaultPartId: String?) -> IMAPBodyStructure.Part? {
    guard case .list(let items) = tok, items.count >= 2 else { return nil }
    var idx = 0
    func str(_ i: Int) -> String? { if i < items.count, case .atomOrString(let s) = items[i] { return s } ; return nil }
    guard let type = str(idx)?.uppercased() else { return nil }; idx += 1
    guard let subType = str(idx)?.uppercased() else { return nil }; idx += 1
    var params: [String: String] = [:]
    if idx < items.count, case .list(let pList) = items[idx] { idx += 1; params = dictFromPairs(pList) }
    var size: Int? = nil
    if idx < items.count, case .atomOrString(let szStr) = items[idx], let n = Int(szStr) { size = n; idx += 1 }
    var disposition: String? = nil
    var filename: String? = nil
    // Look for a (disposition ("filename" "name")) style block among the remaining tokens
    for j in idx..<items.count {
        if case .list(let block) = items[j], block.count >= 1, case .atomOrString(let disp) = block.first! {
            disposition = disp.uppercased()
            if block.count >= 2, case .list(let kv) = block[1] {
                let dict = dictFromPairs(kv)
                filename = dict["filename"] ?? dict["name"]
            }
        }
    }
    return IMAPBodyStructure.Part(partId: defaultPartId, type: type, subType: subType, params: params, size: size, disposition: disposition, filename: filename)
}

private func dictFromPairs(_ tokens: [IMAPToken]) -> [String: String] {
    var d: [String: String] = [:]
    var i = 0
    while i + 1 < tokens.count {
        if case .atomOrString(let k) = tokens[i], case .atomOrString(let v) = tokens[i+1] {
            d[k.lowercased()] = v
        }
        i += 2
    }
    return d
}

/// Attempts to extract a literal BODY[...] payload from the raw data using the `{n}\r\n` size marker.
private func extractLiteralBody(fromData data: Data, headerText: String) -> Data? {
    // Look for `{n}\r\n` after a BODY[ marker in the textual view, then slice bytes accordingly.
    guard let bodyMarker = headerText.range(of: "BODY[") ?? headerText.range(of: "BODY[]") else { return nil }
    let tail = headerText[bodyMarker.lowerBound...]
    guard let openBrace = tail.firstIndex(of: "{") else { return nil }
    guard let closeBrace = tail[tail.index(after: openBrace)...].firstIndex(of: "}") else { return nil }
    let numStr = String(tail[tail.index(after: openBrace)..<closeBrace])
    guard let n = Int(numStr), n > 0 else { return nil }
    // Expect CRLF immediately after the closing brace
    guard let cr = tail[closeBrace...].range(of: "\r\n") else { return nil }
    // Byte length of everything up to the end of `}\r\n` in the original data
    let prefix = String(headerText[..<cr.upperBound])
    let headerByteLen = prefix.utf8.count
    let total = data.count
    guard headerByteLen + n <= total else { return nil }
    return data.subdata(in: headerByteLen..<(headerByteLen + n))
}

private func extractFlags(fromFetchLine line: String) -> [String]? {
    // FLAGS (\Seen \Answered)
    guard let r = line.range(of: "FLAGS (") else { return nil }
    let tail = line[r.upperBound...]
    guard let end = tail.firstIndex(of: ")") else { return nil }
    let raw = tail[..<end]
    let parts = raw.split(whereSeparator: \.isWhitespace).map { String($0) }
    return parts
}

private func extractInternalDate(from line: String) -> Date? {
    // INTERNALDATE "01-Jan-2024 10:00:00 +0000"
    guard let r = line.range(of: "INTERNALDATE \"") else { return nil }
    let tail = line[r.upperBound...]
    guard let end = tail.firstIndex(of: "\"") else { return nil }
    let dateStr = String(tail[..<end])
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
    return f.date(from: dateStr)
}

private func extractEnvelopeSubject(from line: String) -> String? {
    // ENVELOPE structure: (date subject from ...) -- extract the SECOND quoted string (subject)
    guard let r = line.range(of: "ENVELOPE (") else { return nil }
    let tail = line[r.upperBound...]
    
    // Find first quoted string (date) - skip it
    guard let firstQuote = tail.firstIndex(of: "\"") else { return nil }
    let afterFirst = tail[tail.index(after: firstQuote)...]
    guard let firstClose = afterFirst.firstIndex(of: "\"") else { return nil }
    
    // Find second quoted string (subject)
    let afterFirstField = afterFirst[afterFirst.index(after: firstClose)...]
    guard let secondQuote = afterFirstField.firstIndex(of: "\"") else { return nil }
    let afterSecond = afterFirstField[afterFirstField.index(after: secondQuote)...]
    guard let secondClose = afterSecond.firstIndex(of: "\"") else { return nil }
    
    let subj = String(afterSecond[..<secondClose])
    if subj.uppercased() == "NIL" { return nil }
    return subj
}

private func extractEnvelopeFrom(from line: String) -> String? {
    // ENVELOPE structure: (date subject from sender reply-to to cc bcc in-reply-to message-id)
    // FROM is the THIRD field: (("Name" NIL "mailbox" "host"))
    
    guard let envStart = line.range(of: "ENVELOPE (") else { return nil }
    let afterEnv = line[envStart.upperBound...]
    
    // Skip first field (date) - quoted string
    guard let firstQuote = afterEnv.firstIndex(of: "\"") else { return nil }
    let afterFirstQuote = afterEnv[afterEnv.index(after: firstQuote)...]
    guard let firstClose = afterFirstQuote.firstIndex(of: "\"") else { return nil }
    
    // Skip second field (subject) - quoted string
    let afterSubject = afterFirstQuote[afterFirstQuote.index(after: firstClose)...]
    guard let secondQuote = afterSubject.firstIndex(of: "\"") else { return nil }
    let afterSecondQuote = afterSubject[afterSubject.index(after: secondQuote)...]
    guard let secondClose = afterSecondQuote.firstIndex(of: "\"") else { return nil }
    
    // Now we're at the FROM field - should start with ((
    let afterFromStart = afterSecondQuote[afterSecondQuote.index(after: secondClose)...]
    guard let fromListStart = afterFromStart.range(of: "((") else { return nil }
    let fromContent = afterFromStart[fromListStart.upperBound...]
    
    // Parse: ("Display Name" NIL "mailbox" "host")
    // Extract all quoted strings from this address structure
    var quotedStrings: [String] = []
    var searchRange = fromContent.startIndex
    
    while searchRange < fromContent.endIndex {
        guard let quoteStart = fromContent[searchRange...].firstIndex(of: "\"") else { break }
        let afterQuote = fromContent.index(after: quoteStart)
        guard afterQuote < fromContent.endIndex else { break }
        
        // Find the closing quote (handle escaped quotes)
        var quoteEnd = afterQuote
        var escaped = false
        while quoteEnd < fromContent.endIndex {
            let char = fromContent[quoteEnd]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "\"" {
                break
            }
            quoteEnd = fromContent.index(after: quoteEnd)
        }
        
        if quoteEnd < fromContent.endIndex {
            let content = String(fromContent[afterQuote..<quoteEnd])
            if content.uppercased() != "NIL" && !content.isEmpty {
                quotedStrings.append(content)
            }
            searchRange = fromContent.index(after: quoteEnd)
        } else {
            break
        }
        
        // Stop after we have enough (name, mailbox, host)
        if quotedStrings.count >= 3 { break }
    }
    
    // Build the FROM string based on what we found
    switch quotedStrings.count {
    case 0:
        return nil
    case 1:
        // Only name or only email
        return quotedStrings[0]
    case 2:
        // mailbox@host (no display name)
        return "\(quotedStrings[0])@\(quotedStrings[1])"
    case 3...:
        // Display Name + mailbox@host
        let name = quotedStrings[0]
        let mailbox = quotedStrings[1]
        let host = quotedStrings[2]
        
        // Format: "Display Name <mailbox@host>"
        return "\(name) <\(mailbox)@\(host)>"
    default:
        return nil
    }
}

private func lastToken(from slice: Substring) -> String? {
    let comps = slice.split(whereSeparator: \.isWhitespace)
    guard let last = comps.last else { return nil }
    return String(last).trimmingCharacters(in: CharacterSet(charactersIn: "\"()"))
}

private func firstToken(from slice: Substring) -> String? {
    let comps = slice.split(whereSeparator: \.isWhitespace)
    guard let first = comps.first else { return nil }
    return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"()"))
}

private func trimTrailingParens(_ s: String) -> String {
    var out = s
    while out.last == ")" { out.removeLast() }
    return out
}
