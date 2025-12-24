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

public enum BodyStructure: Sendable, Equatable {
    case single(Part)
    case multipart(type: String, subType: String, parts: [BodyStructure])

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

// MARK: - IMAPBodyStructure Extension

public enum IMAPBodyStructure: Sendable, Equatable {
    case text(subtype: String, charset: String?)
    case multipart(subtype: String, parts: [IMAPBodyStructure])
    case application(subtype: String)
    case image(subtype: String)
    case audio(subtype: String)
    case video(subtype: String)
    case message(subtype: String)
    case other(type: String, subtype: String)
    
    var mimeType: String {
        switch self {
        case .text(let subtype, _): return "text/\(subtype)"
        case .application(let subtype): return "application/\(subtype)"
        case .image(let subtype): return "image/\(subtype)"
        case .audio(let subtype): return "audio/\(subtype)"
        case .video(let subtype): return "video/\(subtype)"
        case .message(let subtype): return "message/\(subtype)"
        case .other(let type, let subtype): return "\(type)/\(subtype)"
        case .multipart(let subtype, _): return "multipart/\(subtype)"
        }
    }
    
    var charset: String? {
        if case .text(_, let charset) = self {
            return charset
        }
        return nil
    }
}

public struct FetchResult: Sendable, Equatable {
    public let uid: String?
    public let flags: [String]
    public let internalDate: Date?
    public let envelope: MessageEnvelope?
    public let bodySection: Data?
    public let bodyStructure: BodyStructure?
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

            // From with RFC2047 decoding
            let rawFrom = extractEnvelopeFrom(from: raw) ?? ""
            let from = RFC2047EncodedWordsParser.decodeFrom(rawFrom)

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
        let bodyCandidates = lines.filter { line in
            // Filtere nur echte IMAP-Responses raus, nicht Base64-Daten
            guard !line.hasPrefix("* ") else { return false }  // Untagged responses

            // IMAP Tagged responses haben Format: "Axx OK/NO/BAD ..."
            // Base64-Daten beginnen auch mit "A", aber ohne " OK"/" NO"/" BAD"
            if line.hasPrefix("A") {
                let isTaggedResponse = line.contains(" OK") ||
                                       line.contains(" NO") ||
                                       line.contains(" BAD")
                return !isTaggedResponse
            }
            return true
        }
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

        // From with RFC2047 decoding
        let rawFrom = extractEnvelopeFrom(from: line)
        let from = rawFrom != nil ? RFC2047EncodedWordsParser.decodeFrom(rawFrom!) : nil

        // Date (INTERNALDATE is usually outside envelope, but try to parse if present)
        let date = extractInternalDate(from: line)
        return MessageEnvelope(subject: subject, from: from, to: [], cc: [], bcc: [], date: date, messageId: nil)
    }

    /// Parse BODYSTRUCTURE from a single FETCH line. Produces a lightweight recursive structure.
    public func parseBodyStructure(_ line: String) throws -> BodyStructure {
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
            var parts: [BodyStructure] = []
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
private func decodeAsBodyStructure(_ tok: IMAPToken) throws -> BodyStructure {
    switch tok {
    case .list(let items):
        if items.isEmpty { throw IMAPParseError.invalid("Empty BODYSTRUCTURE list") }
        // Heuristic: multipart starts with subpart lists; single-part starts with type/subtype strings
        if case .list = items.first! {
            // Multipart: collect nested parts lists; subtype may be after the list
            var parts: [BodyStructure] = []
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
private func decodeSinglePart(from tok: IMAPToken, defaultPartId: String?) -> BodyStructure.Part? {
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
    return BodyStructure.Part(partId: defaultPartId, type: type, subType: subType, params: params, size: size, disposition: disposition, filename: filename)
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

// MARK: - IMAPBodyStructure Parser

public func parseBodyStructure(_ response: String) -> IMAPBodyStructure? {
    // Parse BODYSTRUCTURE response into IMAPBodyStructure enum
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Look for BODYSTRUCTURE keyword
    guard let range = trimmed.range(of: "BODYSTRUCTURE ") else { return nil }
    let bodyData = String(trimmed[range.upperBound...])
    
    // Simple parsing logic - this would need to be more robust for production
    if bodyData.lowercased().contains("multipart") {
        // Extract subtype
        if let subtypeRange = bodyData.range(of: "\"") {
            let afterQuote = bodyData[subtypeRange.upperBound...]
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                let subtype = String(afterQuote[..<endQuote]).lowercased()
                return .multipart(subtype: subtype, parts: []) // Simplified
            }
        }
        return .multipart(subtype: "mixed", parts: [])
    } else if bodyData.lowercased().contains("text") {
        // Extract charset if present
        var charset: String? = nil
        if let charsetRange = bodyData.lowercased().range(of: "charset") {
            let afterCharset = bodyData[charsetRange.upperBound...]
            if let quoteStart = afterCharset.firstIndex(of: "\"") {
                let afterQuote = afterCharset[afterCharset.index(after: quoteStart)...]
                if let quoteEnd = afterQuote.firstIndex(of: "\"") {
                    charset = String(afterQuote[..<quoteEnd])
                }
            }
        }
        
        // Extract subtype
        if let subtypeRange = bodyData.range(of: "\"") {
            let afterQuote = bodyData[subtypeRange.upperBound...]
            if let endQuote = afterQuote.firstIndex(of: "\"") {
                let subtype = String(afterQuote[..<endQuote]).lowercased()
                return .text(subtype: subtype, charset: charset)
            }
        }
        return .text(subtype: "plain", charset: charset)
    } else if bodyData.lowercased().contains("application") {
        if let subtypeRange = bodyData.range(of: "\"application/") {
            let afterType = bodyData[subtypeRange.upperBound...]
            if let endQuote = afterType.firstIndex(of: "\"") {
                let subtype = String(afterType[..<endQuote]).lowercased()
                return .application(subtype: subtype)
            }
        }
        return .application(subtype: "octet-stream")
    } else if bodyData.lowercased().contains("image") {
        if let subtypeRange = bodyData.range(of: "\"image/") {
            let afterType = bodyData[subtypeRange.upperBound...]
            if let endQuote = afterType.firstIndex(of: "\"") {
                let subtype = String(afterType[..<endQuote]).lowercased()
                return .image(subtype: subtype)
            }
        }
        return .image(subtype: "jpeg")
    }
    
    // Fallback to other type
    return .other(type: "unknown", subtype: "unknown")
}
