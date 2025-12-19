// AILO_APP/Services/Mail/IMAP/IMAPCommands_Phase2.swift
// PHASE 2: Section-based Fetching Extensions
// Adds targeted section fetches and partial byte range fetching

import Foundation

// MARK: - IMAPCommands Phase 2 Extension

extension IMAPCommands {
    
    // MARK: - Section Fetch (Targeted)
    
    /// Fetch a specific MIME section (e.g. "1.2" or "TEXT")
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uid: Message UID
    ///   - section: Section identifier (e.g. "1", "1.2", "TEXT", "HEADER")
    ///   - peek: Use PEEK to avoid marking as seen
    ///   - idleTimeout: Timeout for response
    /// - Returns: Raw response lines
    public func uidFetchSection(_ conn: IMAPConnection, uid: String, section: String, 
                                peek: Bool = true, idleTimeout: TimeInterval = 20.0) async throws -> [String] {
        let t = Tagger().next()
        let peekStr = peek ? "PEEK" : ""
        let sectionStr = section.isEmpty ? "" : "[\(section)]"
        let command = "UID FETCH \(uid) (BODY\(peekStr)\(sectionStr))"
        
        print("📥 [IMAPCommands] Fetching section: \(section) for UID \(uid)")
        
        try await conn.send(line: "\(t) \(command)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        
        print("✅ [IMAPCommands] Received \(lines.count) lines for section \(section)")
        return lines
    }
    
    /// Fetch multiple sections in one request (efficient batch fetch)
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uid: Message UID
    ///   - sections: Array of section identifiers
    ///   - peek: Use PEEK to avoid marking as seen
    ///   - idleTimeout: Timeout for response
    /// - Returns: Raw response lines (multiple sections)
    public func uidFetchSections(_ conn: IMAPConnection, uid: String, sections: [String],
                                 peek: Bool = true, idleTimeout: TimeInterval = 30.0) async throws -> [String] {
        guard !sections.isEmpty else { return [] }
        
        let t = Tagger().next()
        let peekStr = peek ? "PEEK" : ""
        
        // Build command: BODY.PEEK[1] BODY.PEEK[2] ...
        let sectionParts = sections.map { "BODY\(peekStr)[\($0)]" }.joined(separator: " ")
        let command = "UID FETCH \(uid) (\(sectionParts))"
        
        print("📥 [IMAPCommands] Fetching \(sections.count) sections for UID \(uid)")
        
        try await conn.send(line: "\(t) \(command)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        
        print("✅ [IMAPCommands] Received \(lines.count) lines for multiple sections")
        return lines
    }
    
    // MARK: - Partial Fetch (Byte Range)
    
    /// Fetch partial bytes from a section (RFC3501 §6.4.5)
    /// Useful for large attachments or progressive loading
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uid: Message UID
    ///   - section: Section identifier (or empty for full message)
    ///   - startByte: Start offset (0-based)
    ///   - endByte: End offset (inclusive), or nil for "to end"
    ///   - peek: Use PEEK to avoid marking as seen
    ///   - idleTimeout: Timeout for response
    /// - Returns: Raw response lines
    public func uidFetchPartial(_ conn: IMAPConnection, uid: String, section: String = "",
                                startByte: Int, endByte: Int? = nil,
                                peek: Bool = true, idleTimeout: TimeInterval = 30.0) async throws -> [String] {
        let t = Tagger().next()
        let peekStr = peek ? "PEEK" : ""
        let sectionStr = section.isEmpty ? "" : "[\(section)]"
        
        // Format: BODY.PEEK[section]<start.length>
        let rangeStr: String
        if let end = endByte {
            let length = max(0, end - startByte + 1)
            rangeStr = "<\(startByte).\(length)>"
        } else {
            // Fetch from start to end of section
            rangeStr = "<\(startByte)>"
        }
        
        let command = "UID FETCH \(uid) (BODY\(peekStr)\(sectionStr)\(rangeStr))"
        
        print("📥 [IMAPCommands] Fetching partial: section=\(section), range=\(startByte)-\(endByte?.description ?? "end")")
        
        try await conn.send(line: "\(t) \(command)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        
        print("✅ [IMAPCommands] Received \(lines.count) lines for partial fetch")
        return lines
    }
    
    // MARK: - BODYSTRUCTURE with Metadata
    
    /// Fetch BODYSTRUCTURE, ENVELOPE, and basic metadata in one request
    /// This is the optimal Phase 2 entry point for message processing
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uid: Message UID
    ///   - idleTimeout: Timeout for response
    /// - Returns: Raw response lines with all metadata
    public func uidFetchStructureAndMetadata(_ conn: IMAPConnection, uid: String,
                                            idleTimeout: TimeInterval = 15.0) async throws -> [String] {
        let t = Tagger().next()
        
        // Fetch everything we need for analysis (no body content yet)
        let command = "UID FETCH \(uid) (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)"
        
        print("📥 [IMAPCommands] Fetching structure + metadata for UID \(uid)")
        
        try await conn.send(line: "\(t) \(command)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        
        print("✅ [IMAPCommands] Received metadata (\(lines.count) lines)")
        return lines
    }
    
    /// Batch fetch BODYSTRUCTURE for multiple UIDs (efficient for folder scan)
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uids: Array of message UIDs
    ///   - idleTimeout: Timeout for response
    /// - Returns: Raw response lines for all messages
    public func uidFetchStructuresAndMetadata(_ conn: IMAPConnection, uids: [String],
                                             idleTimeout: TimeInterval = 30.0) async throws -> [String] {
        guard !uids.isEmpty else { return [] }
        
        let t = Tagger().next()
        let uidSet = joinUIDSet(uids)
        
        let command = "UID FETCH \(uidSet) (UID FLAGS INTERNALDATE ENVELOPE BODYSTRUCTURE)"
        
        print("📥 [IMAPCommands] Fetching structures for \(uids.count) UIDs")
        
        try await conn.send(line: "\(t) \(command)")
        let lines = try await conn.receiveLines(untilTag: t, idleTimeout: idleTimeout)
        
        print("✅ [IMAPCommands] Received \(lines.count) lines for batch fetch")
        return lines
    }
    
    // MARK: - Helper: Smart Body Fetch
    
    /// Intelligent body fetch based on content type hints
    /// Automatically determines best sections to fetch
    /// - Parameters:
    ///   - conn: IMAP connection
    ///   - uid: Message UID
    ///   - bodyStructure: Pre-parsed BODYSTRUCTURE (from Phase 1 fetch)
    ///   - fetchInlineImages: Whether to fetch inline images immediately
    ///   - peek: Use PEEK to avoid marking as seen
    /// - Returns: Raw response lines for body content
    public func uidFetchSmartBody(_ conn: IMAPConnection, uid: String,
                                  bodyStructure: BodyStructure,
                                  fetchInlineImages: Bool = false,
                                  peek: Bool = true) async throws -> [String] {
        // Analyze structure to determine best sections
        let analyzer = BodyStructureAnalyzer(structure: bodyStructure)
        
        var sectionsToFetch: [String] = []
        
        // Always fetch body (HTML preferred, text fallback)
        if let htmlSection = analyzer.findSection(mediaType: "text/html") {
            sectionsToFetch.append(htmlSection)
        } else if let textSection = analyzer.findSection(mediaType: "text/plain") {
            sectionsToFetch.append(textSection)
        }
        
        // Optionally fetch inline images
        if fetchInlineImages {
            let inlineImages = analyzer.findInlineParts(disposition: "inline", 
                                                        mediaTypes: ["image/png", "image/jpeg", "image/gif"])
            sectionsToFetch.append(contentsOf: inlineImages)
        }
        
        guard !sectionsToFetch.isEmpty else {
            // Fallback: fetch entire body
            return try await uidFetchBody(conn, uid: uid, partsOrPeek: peek ? "BODY.PEEK[]" : "BODY[]")
        }
        
        print("📥 [IMAPCommands] Smart fetch: \(sectionsToFetch.count) sections identified")
        
        // Batch fetch all needed sections
        return try await uidFetchSections(conn, uid: uid, sections: sectionsToFetch, peek: peek)
    }
}

// MARK: - Helper: BodyStructureAnalyzer

/// Analyzes BODYSTRUCTURE to determine which sections to fetch
struct BodyStructureAnalyzer {
    let structure: BodyStructure
    
    /// Find section ID for a specific media type
    func findSection(mediaType: String) -> String? {
        return findSectionRecursive(in: structure, targetType: mediaType, currentPath: "")
    }
    
    /// Find all inline parts with specific media types
    func findInlineParts(disposition: String, mediaTypes: [String]) -> [String] {
        var results: [String] = []
        findInlineRecursive(in: structure, disposition: disposition, 
                           mediaTypes: mediaTypes, currentPath: "", results: &results)
        return results
    }
    
    /// Find body candidate parts (text/html or text/plain)
    func findBodyCandidates() -> [String] {
        var candidates: [String] = []
        
        // Prefer HTML
        if let htmlSection = findSection(mediaType: "text/html") {
            candidates.append(htmlSection)
        }
        
        // Fallback to plain text
        if let textSection = findSection(mediaType: "text/plain") {
            candidates.append(textSection)
        }
        
        return candidates
    }
    
    // MARK: - Private Recursive Helpers
    
    private func findSectionRecursive(in structure: BodyStructure, 
                                     targetType: String, 
                                     currentPath: String) -> String? {
        switch structure {
        case .single(let part):
            let fullType = "\(part.type)/\(part.subType)".lowercased()
            if fullType == targetType.lowercased() {
                return part.partId ?? currentPath.isEmpty ? "1" : currentPath
            }
            return nil
            
        case .multipart(_, _, let parts):
            for (index, subPart) in parts.enumerated() {
                let subPath = currentPath.isEmpty ? "\(index + 1)" : "\(currentPath).\(index + 1)"
                if let found = findSectionRecursive(in: subPart, targetType: targetType, currentPath: subPath) {
                    return found
                }
            }
            return nil
        }
    }
    
    private func findInlineRecursive(in structure: BodyStructure,
                                    disposition: String,
                                    mediaTypes: [String],
                                    currentPath: String,
                                    results: inout [String]) {
        switch structure {
        case .single(let part):
            let fullType = "\(part.type)/\(part.subType)".lowercased()
            let matchesType = mediaTypes.contains { $0.lowercased() == fullType }
            let matchesDisposition = part.disposition?.lowercased() == disposition.lowercased()
            
            if matchesType && (matchesDisposition || part.disposition == nil) {
                let sectionId = part.partId ?? (currentPath.isEmpty ? "1" : currentPath)
                results.append(sectionId)
            }
            
        case .multipart(_, _, let parts):
            for (index, subPart) in parts.enumerated() {
                let subPath = currentPath.isEmpty ? "\(index + 1)" : "\(currentPath).\(index + 1)"
                findInlineRecursive(in: subPart, disposition: disposition, 
                                  mediaTypes: mediaTypes, currentPath: subPath, results: &results)
            }
        }
    }
}
