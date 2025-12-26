// AILO_APP/Configuration/Services/Mail/IMAPCommands.swift
// Stateless helpers for issuing IMAP commands via IMAPConnection.
// Provides methods like greeting(), login(), listFolders(), select(folder:), search(query:), fetchEnvelope(), fetchBody(uid:).
// Returns raw or parsed responses; no persistence or business logic.
// NOTE: Keep this file free of UI and storage concerns. Parsing that is complex should live in IMAPParsers.

import Foundation


// MARK: - IMAPCommands

public struct IMAPCommands {
    public init() {}

    // Generates unique incremental tags: A1, A2, ...
    private final class Tagger {
        private var n: Int = 0
        func next() -> String { n += 1; return "A\(n)" }
    }

    // MARK: Session

    public func greeting(_ conn: IMAPConnection, idleTimeout: TimeInterval = 5.0) async throws -> [String] {
        // Use specialized receiveGreeting() for initial server greeting
        // Returns a single line like "* OK IMAP4rev1 Service Ready"
        let greetingLine = try await conn.receiveGreeting(timeout: idleTimeout)
        return [greetingLine]
    }

    public func login(_ conn: IMAPConnection, user: String, pass: String, idleTimeout: TimeInterval = 8.0) async throws {
        let t = Tagger().next()
        // Auth PLAIN LOGIN (simple variant). Later: XOAUTH2, SASL, etc.
        try await conn.send(line: "\(t) LOGIN \(quote(user)) \(quote(pass))")
        _ = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func logout(_ conn: IMAPConnection, idleTimeout: TimeInterval = 4.0) async throws {
        let t = Tagger().next()
        try await conn.send(line: "\(t) LOGOUT")
        _ = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }
    public func startTLS(_ conn: IMAPConnection, idleTimeout: TimeInterval = 5.0) async throws {
        let t = Tagger().next()
        try await conn.send(line: "\(t) STARTTLS")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        // Verify server accepted STARTTLS
        guard let last = lines.last, last.hasPrefix("\(t) OK") else {
            throw IMAPError.connectFailed("STARTTLS rejected by server")
        }
        // Now upgrade the connection to TLS
        try await conn.upgradeToTLS()
    }

    // MARK: Folders

    public func capabilities(_ conn: IMAPConnection, idleTimeout: TimeInterval = 6.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) CAPABILITY")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func listAll(_ conn: IMAPConnection, idleTimeout: TimeInterval = 10.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) LIST \"\" \"*\"")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func listSpecialUse(_ conn: IMAPConnection, idleTimeout: TimeInterval = 10.0) async throws -> [String] {
        let t = Tagger().next()
        // RFC 6154 SPECIAL-USE (server may ignore; caller must be resilient)
        try await conn.send(line: "\(t) LIST (SPECIAL-USE) \"\" \"*\"")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func select(_ conn: IMAPConnection, folder: String, readOnly: Bool = true, idleTimeout: TimeInterval = 8.0) async throws -> [String] {
        let t = Tagger().next()
        let cmd = readOnly ? "EXAMINE" : "SELECT"
        try await conn.send(line: "\(t) \(cmd) \(quote(folder))")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    // MARK: Search / Fetch

    public func uidSearch(_ conn: IMAPConnection, query: String = "NOT DELETED", idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID SEARCH \(query)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func uidFetchEnvelope(_ conn: IMAPConnection, uids: [String], peek: Bool = true, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        let t = Tagger().next()
        let set = joinUIDSet(uids)
        // ENVELOPE + INTERNALDATE + FLAGS as a compact header set
        let body = "UID FETCH \(set) (ENVELOPE INTERNALDATE FLAGS)"
        try await conn.send(line: "\(t) \(body)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }
    
    // ✅ NEU: PHASE 1 - BODYSTRUCTURE für Attachment-Erkennung
    public func uidFetchEnvelopeWithStructure(_ conn: IMAPConnection, uids: [String], peek: Bool = true, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        let t = Tagger().next()
        let set = joinUIDSet(uids)
        // ENVELOPE + INTERNALDATE + FLAGS + BODYSTRUCTURE für Attachment-Info
        let body = "UID FETCH \(set) (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)"
        try await conn.send(line: "\(t) \(body)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func uidFetchFlags(_ conn: IMAPConnection, uids: [String], idleTimeout: TimeInterval = 8.0) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID FETCH \(joinUIDSet(uids)) (FLAGS)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    public func uidFetchBody(_ conn: IMAPConnection, uid: String, partsOrPeek: String = "BODY.PEEK[]", idleTimeout: TimeInterval = 20.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID FETCH \(uid) (\(partsOrPeek))")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }
    
    /// Batch fetch bodies for multiple UIDs (Phase 2 optimization)
    public func uidFetchBody(_ conn: IMAPConnection, uids: [String], partsOrPeek: String = "BODY.PEEK[]", idleTimeout: TimeInterval = 30.0) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        let t = Tagger().next()
        let uidSet = joinUIDSet(uids)
        try await conn.send(line: "\(t) UID FETCH \(uidSet) (\(partsOrPeek))")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    /// High-level SEARCH that returns UIDs as strings for the given raw IMAP criteria.
    /// This is a convenience over `uidSearch(…)` that parses the returned lines to extract UIDs.
    public func search(_ conn: IMAPConnection, criteria: String, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID SEARCH \(criteria)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        // Find the * SEARCH line and parse UIDs
        if let first = lines.first(where: { $0.hasPrefix("* SEARCH ") }) {
            return IMAPParsers().parseUIDs(first)
        }
        return []
    }

    /// High-level SEARCH that accepts `SearchCriteria` and returns UIDs as strings.
    public func search(_ conn: IMAPConnection, criteria: SearchCriteria, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        return try await search(conn, criteria: criteria.toIMAPQuery(), idleTimeout: idleTimeout)
    }
    
    // MARK: - Enhanced Fetch Commands for Optimized Fetching
    
    /// Fetch BODYSTRUCTURE for a specific UID
    public func uidFetchBodyStructure(_ conn: IMAPConnection, uid: String, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID FETCH \(uid) (BODYSTRUCTURE)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }
    
    /// Fetch specific section for a UID
    public func uidFetchSection(_ conn: IMAPConnection, uid: String, section: String, idleTimeout: TimeInterval = 20.0) async throws -> [String] {
        let t = Tagger().next()
        try await conn.send(line: "\(t) UID FETCH \(uid) (BODY.PEEK[\(section)])")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    /// High-level FETCH that issues a generic UID FETCH for the given item list and returns raw response lines.
    /// For typed parsing, use IMAPParsers to interpret the returned lines into models.
    public func fetch(_ conn: IMAPConnection, uids: [String], items: [String], peek: Bool = true, idleTimeout: TimeInterval = 12.0) async throws -> [String] {
        guard !uids.isEmpty, !items.isEmpty else { return [] }
        let t = Tagger().next()
        let set = joinUIDSet(uids)
        // Apply .PEEK to BODY requests when requested; otherwise pass items as-is
        let resolvedItems: [String] = items.map { itm in
            if peek, itm.uppercased().hasPrefix("BODY") && !itm.uppercased().contains("PEEK") {
                return itm.replacingOccurrences(of: "BODY", with: "BODY.PEEK")
            }
            return itm
        }
        let body = "UID FETCH \(set) (\(resolvedItems.joined(separator: " ")))"
        try await conn.send(line: "\(t) \(body)")
        return try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
    }

    // MARK: Light parsing helpers (optional)

    /// Extract UIDs from a `* SEARCH` line: "* SEARCH 123 456 789"
    public func parseSearchUIDs(_ lines: [String]) -> [String] {
        for line in lines {
            if line.hasPrefix("* SEARCH ") {
                let rest = line.dropFirst(9)
                return rest.split(separator: " ").map { String($0) }
            }
        }
        return []
    }

    /// Very shallow envelope parse stub (subject/from only). Real logic should live in IMAPParsers.
    public func parseEnvelopesShallow(_ lines: [String]) -> [EnvelopeRecord] {
        // This keeps it intentionally minimal; a full ENVELOPE parser goes to IMAPParsers.
        var result: [EnvelopeRecord] = []
        for line in lines where line.contains(" UID ") {
            // Try to find UID
            let comps = line.split(separator: " ")
            guard let uidIdx = comps.firstIndex(of: Substring("UID")), uidIdx + 1 < comps.count else { continue }
            let uid = String(comps[uidIdx + 1])
            // Subject heuristic (placeholder)
            let subject = extractQuoted(after: "ENVELOPE (", in: line) ?? ""
            result.append(EnvelopeRecord(uid: uid, subject: subject, from: "", internalDate: nil))
        }
        return result
    }

    public func parseFlagsShallow(_ lines: [String]) -> [FlagsRecord] {
        var result: [FlagsRecord] = []
        for line in lines where line.contains(" FLAGS ") && line.contains(" UID ") {
            let comps = line.split(separator: " ")
            guard let uidIdx = comps.firstIndex(of: Substring("UID")), uidIdx + 1 < comps.count else { continue }
            let uid = String(comps[uidIdx + 1])
            // Very crude FLAGS extraction
            if let range = line.range(of: "FLAGS ("),
               let end = line[range.upperBound...].firstIndex(of: ")") {
                let raw = line[range.upperBound..<end]
                let flags = raw.split(separator: " ").map { String($0) }
                result.append(FlagsRecord(uid: uid, flags: flags))
            }
        }
        return result
    }

    // MARK: - Helpers

    public func joinUIDSet(_ uids: [String]) -> String {
        // Compact ranges later; for now simply join
        return uids.joined(separator: ",")
    }

    public func quote(_ s: String) -> String {
        // IMAP quoted string; naive implementation for now
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func extractQuoted(after token: String, in line: String) -> String? {
        guard let range = line.range(of: token) else { return nil }
        let tail = line[range.upperBound...]
        guard let firstQuote = tail.firstIndex(of: "\"") else { return nil }
        let rest = tail[tail.index(after: firstQuote)...]
        guard let second = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<second])
    }
}

// MARK: - High-level convenience API (stateless helpers wrapped into a connection-owning client)

/// Minimal header model returned by `fetchHeaders`.
public struct IMAPMessage: Sendable, Identifiable, Equatable {
    public var id: String { uid }
    public let uid: String
    public let subject: String
    public let from: String
    public let internalDate: Date?
    public let flags: [String]
    public let hasAttachments: Bool  // ✅ NEU: PHASE 3 - Attachment-Flag
    
    public init(uid: String, subject: String, from: String, internalDate: Date?, flags: [String], hasAttachments: Bool = false) {
        self.uid = uid
        self.subject = subject
        self.from = from
        self.internalDate = internalDate
        self.flags = flags
        self.hasAttachments = hasAttachments
    }
}

/// Search criteria builder for IMAP UID SEARCH
public indirect enum SearchCriteria: Sendable, Equatable {
    case all
    case seen
    case unseen
    case flagged
    case unflagged
    case from(String)
    case to(String)
    case subject(String)
    case since(Date)     // inclusive
    case before(Date)    // message internaldate strictly before
    case and([SearchCriteria])
    case or(SearchCriteria, SearchCriteria)

    public func toIMAPQuery() -> String {
        switch self {
        case .all: return "ALL"
        case .seen: return "SEEN"
        case .unseen: return "UNSEEN"
        case .flagged: return "FLAGGED"
        case .unflagged: return "UNFLAGGED"
        case .from(let s): return "FROM \(quoteAtom(s))"
        case .to(let s): return "TO \(quoteAtom(s))"
        case .subject(let s): return "SUBJECT \(quoteAtom(s))"
        case .since(let d): return "SINCE \(imapDate(d))"
        case .before(let d): return "BEFORE \(imapDate(d))"
        case .and(let arr):
            if arr.isEmpty { return "ALL" }
            return arr.map { $0.toIMAPQuery() }.joined(separator: " ")
        case .or(let a, let b):
            return "OR \(a.toIMAPQuery()) \(b.toIMAPQuery())"
        }
    }

    private func quoteAtom(_ s: String) -> String {
        // Reuse the same quoting style as commands.quote but locally (avoid fileprivate access)
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy"
        return f.string(from: date)
    }
}

/// STORE modes: add, remove, or replace the flag set
public enum StoreMode: Sendable {
    case add
    case remove
    case replace
}

/// Events observed while in IDLE mode.
public enum IMAPEvent: Sendable, Equatable {
    case exists(Int)                 // "* 23 EXISTS" (message count)
    case expunge(Int)                // "* 23 EXPUNGE" (sequence number)
    case flags(uid: String, [String])// "* n FETCH (UID x FLAGS (...))"
    case other(String)
}

/// A small, focused client that issues high-level commands using a bound IMAPConnection.
/// It composes the existing low-level IMAPCommands and IMAPParsers without introducing storage/UI concerns.
public final class IMAPClient {
    private let conn: IMAPConnection
    private let commands = IMAPCommands()
    private let parsers = IMAPParsers()

    // Local tagger (independent from IMAPCommands' private Tagger)
    private final class Tagger { var n = 0; func next() -> String { n += 1; return "C\(n)" } }
    private let tagger = Tagger()

    public init(connection: IMAPConnection) {
        self.conn = connection
    }

    // MARK: - FETCH (Headers)

    /// Fetches lightweight headers (ENVELOPE, INTERNALDATE, FLAGS) for the given UIDs.
    /// The `fields` parameter is accepted for future extension; currently ENVELOPE/INTERNALDATE/FLAGS are always returned.
    public func fetchHeaders(uids: [String], fields: [String] = ["ENVELOPE","INTERNALDATE","FLAGS"]) async throws -> [IMAPMessage] {
        guard !uids.isEmpty else { return [] }
        // ✅ NEU: PHASE 4 - BODYSTRUCTURE mitladen für Attachment-Info
        let lines = try await commands.uidFetchEnvelopeWithStructure(conn, uids: uids, peek: true)
        let envs = parsers.parseEnvelope(lines)
        let flagRecs = parsers.parseFlags(lines)
        let flagsByUID = Dictionary(uniqueKeysWithValues: flagRecs.map { ($0.uid, $0.flags) })
        
        // ✅ NEU: Attachment-Status aus BODYSTRUCTURE parsen
        var attachmentsByUID: [String: Bool] = [:]
        for line in lines {
            guard line.contains(" FETCH "), let uid = parsers.extractUID(fromFetchLine: line) else { continue }
            attachmentsByUID[uid] = parsers.hasAttachmentsFromBodyStructure(line)
        }
        
        // Merge into IMAPMessage models; keep original order by supplied UIDs when possible
        var map: [String: IMAPMessage] = [:]
        for e in envs {
            let flags = flagsByUID[e.uid] ?? []
            let hasAttachments = attachmentsByUID[e.uid] ?? false
            map[e.uid] = IMAPMessage(uid: e.uid, subject: e.subject, from: e.from, internalDate: e.internalDate, flags: flags, hasAttachments: hasAttachments)
        }
        // Preserve order of the provided UID list, append any extra found records
        var out: [IMAPMessage] = []
        for u in uids { if let m = map[u] { out.append(m) } }
        if out.count < map.count {
            let extras = map.keys.filter { k in !uids.contains(k) }.compactMap { map[$0] }
            out.append(contentsOf: extras)
        }
        return out
    }

    // MARK: - FETCH (Body)

    /// Fetches a body section for a single message UID. Common sections are "TEXT", "1", "1.2", or empty for the full body.
    public func fetchBody(uid: String, section: String = "") async throws -> Data {
        let spec = section.isEmpty ? "BODY.PEEK[]" : "BODY.PEEK[\(section)]"
        let lines = try await commands.uidFetchBody(conn, uid: uid, partsOrPeek: spec)
        if let bodyString = IMAPParsers().parseBodySection(lines) {
            return Data(bodyString.utf8)
        }
        // Fallback: return the joined raw lines (best-effort; literal bodies should have been materialized by transport)
        let joined = lines.filter { !$0.hasPrefix("A") }.joined(separator: "\n")
        return Data(joined.utf8)
    }

    // MARK: - SEARCH

    /// Runs a UID SEARCH with the given criteria and returns the list of UIDs (as strings).
    public func search(criteria: SearchCriteria) async throws -> [String] {
        let query = criteria.toIMAPQuery()
        let lines = try await commands.uidSearch(conn, query: query)
        // Prefer robust parser; fallback to simple extractor
        if let first = lines.first(where: { $0.hasPrefix("* SEARCH ") }) {
            return parsers.parseUIDs(first)
        }
        return commands.parseSearchUIDs(lines)
    }

    // MARK: - STORE (set/remove/replace flags)

    /// Applies flag changes using UID STORE. Uses SILENT variants to avoid large unsolicited responses.
    public func store(uids: [String], flags: [String], mode: StoreMode) async throws {
        guard !uids.isEmpty else { return }
        let set = uids.joined(separator: ",")
        let op: String
        switch mode {
        case .add: op = "+FLAGS.SILENT"
        case .remove: op = "-FLAGS.SILENT"
        case .replace: op = "FLAGS.SILENT"
        }
        let list = "(\(flags.joined(separator: " ")))"
        let tag = tagger.next()
        try await conn.send(line: "\(tag) UID STORE \(set) \(op) \(list)")
        _ = try await conn.receiveLines(untilTag: tag, idleTimeout: 10)
    }

    // MARK: - IDLE (push notifications)

    /// Starts an IDLE session for up to `timeout` seconds and invokes `callback` for each observed IMAP event.
    /// This method returns after sending DONE and confirming the tagged completion.
    public func idle(timeout: TimeInterval, callback: @escaping (IMAPEvent) -> Void) async throws {
        let tag = tagger.next()
        try await conn.send(line: "\(tag) IDLE")
        // Expect "+ idling" prompt before untagged notifications start
        let prompt = try await conn.receiveLines(untilTag: nil, idleTimeout: 5)
        // Some servers return a single "+ idling" line; ignore if not present
        _ = prompt

        let deadline = Date().addingTimeInterval(max(1, timeout))
        while Date() < deadline {
            // Read with a short idle to stay responsive
            let lines = try await conn.receiveLines(untilTag: nil, idleTimeout: 2)
            for line in lines {
                if let ev = parseIdleEvent(line) {
                    callback(ev)
                }
            }
        }
        // Terminate IDLE
        try await conn.send(line: "DONE")
        _ = try await conn.receiveLines(untilTag: tag, idleTimeout: 5)
    }

    // MARK: - Phase 5: Bidirectional Sync Commands
    
    /// STORE command for flag manipulation (Phase 5)
    /// Supports +FLAGS, -FLAGS, FLAGS operations for bidirectional sync
    public func storeFlags(uid: String, flags: [String], operation: String, idleTimeout: TimeInterval = 8.0) async throws {
        let tag = tagger.next()
        let flagList = flags.map { "\\\\?\($0)" }.joined(separator: " ")
        try await conn.send(line: "\(tag) UID STORE \(uid) \(operation) (\(flagList))")
        _ = try await conn.receiveLines(untilTag: tag, idleTimeout: idleTimeout)
    }
    
    /// STORE command for multiple UIDs (batch flag updates)
    public func storeFlags(uids: [String], flags: [String], operation: String, idleTimeout: TimeInterval = 10.0) async throws {
        guard !uids.isEmpty else { return }
        let tag = tagger.next()
        let uidSet = commands.joinUIDSet(uids)
        let flagList = flags.map { "\\\\?\($0)" }.joined(separator: " ")
        try await conn.send(line: "\(tag) UID STORE \(uidSet) \(operation) (\(flagList))")
        _ = try await conn.receiveLines(untilTag: tag, idleTimeout: idleTimeout)
    }
    
    /// EXPUNGE command for permanent deletion (Phase 5)
    public func expunge(idleTimeout: TimeInterval = 10.0) async throws {
        let tag = tagger.next()
        try await conn.send(line: "\(tag) EXPUNGE")
        _ = try await conn.receiveLines(untilTag: tag, idleTimeout: idleTimeout)
    }
    
    /// APPEND command for adding messages to folders (Phase 5)
    /// Used for adding sent messages to Sent folder
    public func append(folder: String, message: String, flags: [String] = [], idleTimeout: TimeInterval = 15.0) async throws {
        let tag = tagger.next()
        var cmd = "\(tag) APPEND \(commands.quote(folder))"

        // Add flags if provided (format: (\Seen \Flagged))
        if !flags.isEmpty {
            let flagList = flags.map { "\\\($0)" }.joined(separator: " ")
            cmd += " (\(flagList))"
        }

        // Build the literal data: message + terminating CRLF
        // IMAP literal size must exactly match the bytes that follow
        let literalData = (message + "\r\n").data(using: .utf8) ?? Data()
        cmd += " {\(literalData.count)}"

        try await conn.send(line: cmd)

        // Server should respond with continuation (+)
        let continuation = try await conn.receiveLines(untilTag: nil, idleTimeout: 5.0)
        guard continuation.first?.hasPrefix("+") == true else {
            throw IMAPError.protocolError("Expected continuation response for APPEND, got: \(continuation.first ?? "nothing")")
        }

        // Send raw literal data (message + CRLF) - don't use send(line:) as it adds extra CRLF
        try await conn.sendRaw(literalData)

        // Wait for OK response
        let response = try await conn.receiveLines(untilTag: tag, idleTimeout: idleTimeout)

        // Check for success
        if let lastLine = response.last, lastLine.contains("NO") || lastLine.contains("BAD") {
            throw IMAPError.protocolError("APPEND failed: \(lastLine)")
        }
    }

    // MARK: - Helpers

    // MARK: - Attachment Download Methods
    
    /// Fetch a specific body section (for attachment downloads)
    /// Uses the existing uidFetchSection method from IMAPCommands
    func fetchSection(section: String) async throws -> Data {
        // Parse section to extract UID and section part
        // Expected format: "uid.section" e.g., "123.1.2" means UID=123, section=1.2
        let parts = section.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let uid = String(parts[0]).isEmpty ? nil : String(parts[0]),
              !String(parts[1]).isEmpty else {
            throw IMAPError.protocolError("Invalid section format. Expected 'uid.section'")
        }
        
        let sectionPart = String(parts[1])
        let lines = try await commands.uidFetchSection(conn, uid: uid, section: sectionPart)
        
        // Parse the body data from IMAP response
        if let bodyString = parsers.parseBodySection(lines) {
            return Data(bodyString.utf8)
        }
        
        throw IMAPError.protocolError("Failed to parse body section from IMAP response")
    }
    
    /// Fetch partial data from a body section (for large attachment downloads)
    /// Implements IMAP BODY.PEEK[section]<offset.length> for chunked downloads
    func fetchPartial(section: String, offset: Int, length: Int) async throws -> Data {
        // Parse section to extract UID and section part
        let parts = section.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let uid = String(parts[0]).isEmpty ? nil : String(parts[0]),
              !String(parts[1]).isEmpty else {
            throw IMAPError.protocolError("Invalid section format. Expected 'uid.section'")
        }
        
        let sectionPart = String(parts[1])
        let tag = tagger.next()
        
        // Send IMAP command for partial fetch: BODY.PEEK[section]<offset.length>
        let cmd = "\(tag) UID FETCH \(uid) (BODY.PEEK[\(sectionPart)]<\(offset).\(length)>)"
        try await conn.send(line: cmd)
        let lines = try await conn.receiveLines(untilTag: tag, idleTimeout: 20.0)
        
        // Parse the partial body data from IMAP response
        if let bodyString = parsers.parseBodySection(lines) {
            return Data(bodyString.utf8)
        }
        
        throw IMAPError.protocolError("Failed to parse partial body section from IMAP response")
    }
    
    private func parseIdleEvent(_ line: String) -> IMAPEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("* ") else { return nil }
        // * 23 EXISTS
        if trimmed.contains(" EXISTS") {
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3, let n = Int(parts[1]) { return .exists(n) }
        }
        // * 23 EXPUNGE
        if trimmed.contains(" EXPUNGE") {
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            if parts.count >= 3, let n = Int(parts[1]) { return .expunge(n) }
        }
        // * n FETCH (UID 123 FLAGS (...))
        if trimmed.contains(" FETCH ") && trimmed.contains(" UID ") && trimmed.contains(" FLAGS ") {
            // Extract UID
            let tokens = trimmed.split(whereSeparator: \.isWhitespace)
            if let uidIdx = tokens.firstIndex(of: Substring("UID")), uidIdx + 1 < tokens.count {
                let uid = String(tokens[uidIdx + 1]).trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                // Extract flags
                if let r = trimmed.range(of: "FLAGS ("), let end = trimmed[r.upperBound...].firstIndex(of: ")") {
                    let raw = trimmed[r.upperBound..<end]
                    let fl = raw.split(whereSeparator: \.isWhitespace).map { String($0) }
                    return .flags(uid: uid, fl)
                }
            }
        }
        return .other(trimmed)
    }
}

