// AILO_APP/Services/Mail/IMAP/IMAPParsers_Phase2.swift
// PHASE 2: Enhanced BODYSTRUCTURE Parsing
// Adds section ID assignment, disposition parsing, and body candidate detection

import Foundation

// MARK: - Enhanced BodyStructure Types

/// Enhanced BODYSTRUCTURE with full section tracking
public struct EnhancedBodyStructure: Sendable {
    public let structure: BodyStructure
    public let sections: [SectionInfo]
    public let bodyCandidates: [SectionInfo]
    public let inlineParts: [SectionInfo]
    public let attachments: [SectionInfo]
    
    public init(structure: BodyStructure) {
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
    
    private static func analyzeStructure(_ structure: BodyStructure, 
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
