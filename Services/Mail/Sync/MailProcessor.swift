// Unified mail processing pipeline - single point of truth for mail parsing

import Foundation
import CryptoKit

// MARK: - Processed Mail Structure

/// Complete processed mail with all metadata
public struct ProcessedMail: Sendable {
    // Content
    public let text: String?
    public let html: String?
    
    // Metadata (stored in database)
    public let contentType: String       
    public let charset: String           
    public let transferEncoding: String  
    public let isMultipart: Bool         
    public let rawSize: Int              
    public let processedAt: Date
    
    // Attachments with enhanced metadata
    public let attachments: [ProcessedAttachment]
    
    // Processing metadata
    public let processingMethod: String  
    public let warnings: [String]
    
    public init(text: String?, html: String?, contentType: String, charset: String, 
                transferEncoding: String, isMultipart: Bool, rawSize: Int,
                attachments: [ProcessedAttachment] = [], processingMethod: String = "mime",
                warnings: [String] = []) {
        self.text = text
        self.html = html
        self.contentType = contentType
        self.charset = charset
        self.transferEncoding = transferEncoding
        self.isMultipart = isMultipart
        self.rawSize = rawSize
        self.processedAt = Date()
        self.attachments = attachments
        self.processingMethod = processingMethod
        self.warnings = warnings
    }
}

/// Enhanced attachment with deduplication support
public struct ProcessedAttachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int
    public let data: Data
    
    // Enhanced metadata
    public let contentId: String?        
    public let isInline: Bool            
    public let checksum: String          
    public let partId: String
    
    public init(filename: String, mimeType: String, data: Data, contentId: String? = nil, 
                isInline: Bool = false, partId: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = data.count
        self.data = data
        self.contentId = contentId
        self.isInline = isInline
        self.partId = partId
        
        let hash = SHA256.hash(data: data)
        self.checksum = hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Helper Structures

private struct ContentTypeInfo {
    let mimeType: String
    let charset: String?
    let boundary: String?
    let parameters: [String: String]
    
    var fullType: String {
        return mimeType
    }
    
    init(mimeType: String, charset: String? = nil, boundary: String? = nil, parameters: [String: String] = [:]) {
        self.mimeType = mimeType
        self.charset = charset
        self.boundary = boundary
        self.parameters = parameters
    }
}

private struct MimePart {
    let content: String
    let isAttachment: Bool
}

// MARK: - Unified Mail Processor

/// Phase 3: Unified mail processing pipeline
/// Single point of truth for all mail decoding operations
public actor MailProcessor {
    
    public init() {}
    
    /// Central processing method - single point for all mail content processing
    public func processMailContent(
        rawData: String,
        detectedCharset: String?,
        detectedEncoding: String?,
        contentType: String?
    ) async throws -> ProcessedMail {
        
        var warnings: [String] = []
        
        let finalCharset = detectAndValidateCharset(
            detected: detectedCharset,
            from: rawData,
            warnings: &warnings
        )
        
        let finalEncoding = detectedEncoding ?? detectTransferEncoding(from: rawData)
        let finalContentType = contentType ?? detectContentType(from: rawData)
        
        let decodedData = try decodeTransferEncoding(
            rawData: rawData,
            encoding: finalEncoding,
            warnings: &warnings
        )
        
        let decodedString = try applyCharsetConversion(
            data: decodedData,
            charset: finalCharset,
            warnings: &warnings
        )
        
        let isMultipart = finalContentType.hasPrefix("multipart/")
        let (text, html, attachments) = try extractContentParts(
            content: decodedString,
            contentType: finalContentType,
            isMultipart: isMultipart,
            warnings: &warnings
        )
        
        return ProcessedMail(
            text: text,
            html: html,
            contentType: finalContentType,
            charset: finalCharset,
            transferEncoding: finalEncoding,
            isMultipart: isMultipart,
            rawSize: rawData.count,
            attachments: attachments,
            processingMethod: isMultipart ? "multipart" : "simple",
            warnings: warnings
        )
    }
    
    // MARK: - Charset Detection & Validation
    
    private func detectAndValidateCharset(detected: String?, from rawData: String, warnings: inout [String]) -> String {
        if let detected = detected?.lowercased(), isValidCharset(detected) {
            return detected
        }
        
        if rawData.contains("=?iso-8859-1?") || rawData.contains("charset=iso-8859-1") {
            return "iso-8859-1"
        }
        
        if rawData.contains("=?windows-1252?") || rawData.contains("charset=windows-1252") {
            return "windows-1252"
        }
        
        if isLikelyUTF8(rawData) {
            return "utf-8"
        }
        
        warnings.append("Charset detection failed, using UTF-8 fallback")
        print("MailProcessor Warning: Charset detection failed, using UTF-8 fallback")
        return "utf-8"
    }
    
    private func isValidCharset(_ charset: String) -> Bool {
        let common = ["utf-8", "iso-8859-1", "windows-1252", "ascii", "us-ascii"]
        return common.contains(charset.lowercased())
    }
    
    private func isLikelyUTF8(_ string: String) -> Bool {
        return string.utf8.allSatisfy { _ in true }
    }
    
    // MARK: - Transfer Encoding Processing
    
    private func detectTransferEncoding(from rawData: String) -> String {
        if rawData.contains("Content-Transfer-Encoding: base64") {
            return "base64"
        }
        if rawData.contains("Content-Transfer-Encoding: quoted-printable") {
            return "quoted-printable"
        }
        return "7bit"
    }
    
    private func decodeTransferEncoding(rawData: String, encoding: String, warnings: inout [String]) throws -> Data {
        switch encoding.lowercased() {
        case "base64":
            return try decodeBase64Content(rawData: rawData, warnings: &warnings)
        case "quoted-printable":
            return try decodeQuotedPrintable(rawData: rawData, warnings: &warnings)
        case "7bit", "8bit", "binary":
            return rawData.data(using: .utf8) ?? Data()
        default:
            warnings.append("Unknown transfer encoding: \(encoding), using raw data")
            print("MailProcessor Warning: Unknown transfer encoding: \(encoding)")
            return rawData.data(using: .utf8) ?? Data()
        }
    }
    
    private func decodeBase64Content(rawData: String, warnings: inout [String]) throws -> Data {
        let lines = rawData.components(separatedBy: .newlines)
        var base64Content = ""
        var inBody = false
        
        for line in lines {
            if line.isEmpty && !inBody {
                inBody = true
                continue
            }
            if inBody {
                base64Content += line
            }
        }
        
        guard let decoded = Data(base64Encoded: base64Content) else {
            warnings.append("Base64 decoding failed")
            print("MailProcessor Error: Base64 decoding failed")
            return rawData.data(using: .utf8) ?? Data()
        }
        
        return decoded
    }
    
    private func decodeQuotedPrintable(rawData: String, warnings: inout [String]) throws -> Data {
        let lines = rawData.components(separatedBy: .newlines)
        var decodedContent = ""
        var inBody = false
        
        for line in lines {
            if line.isEmpty && !inBody {
                inBody = true
                continue
            }
            if inBody {
                decodedContent += decodeQuotedPrintableLine(line)
            }
        }
        
        return decodedContent.data(using: .utf8) ?? Data()
    }
    
    private func decodeQuotedPrintableLine(_ line: String) -> String {
        // ✅ Sammle alle Bytes für korrekte UTF-8 Dekodierung
        var bytes: [UInt8] = []
        var i = line.startIndex
        
        while i < line.endIndex {
            let c = line[i]
            
            if c == "=" {
                let nextIdx = line.index(after: i)
                guard nextIdx < line.endIndex else {
                    break  // = am Ende
                }
                
                // Prüfe auf Soft Line Break (=\r oder =\n)
                if line[nextIdx] == "\r" || line[nextIdx] == "\n" {
                    i = line.index(after: nextIdx)
                    if nextIdx < line.endIndex && line[nextIdx] == "\r" {
                        let afterCR = line.index(after: nextIdx)
                        if afterCR < line.endIndex && line[afterCR] == "\n" {
                            i = line.index(after: afterCR)
                        }
                    }
                    continue  // Skip soft break
                }
                
                // Dekodiere =XX
                let hex1Idx = nextIdx
                guard hex1Idx < line.endIndex else { break }
                let hex2Idx = line.index(after: hex1Idx)
                guard hex2Idx < line.endIndex else { break }
                
                let hexString = String(line[hex1Idx...hex2Idx])
                if let byte = UInt8(hexString, radix: 16) {
                    // ✅ Byte sammeln statt einzeln interpretieren
                    bytes.append(byte)
                    i = line.index(after: hex2Idx)
                } else {
                    // Invalid hex - keep original as UTF-8 bytes
                    bytes.append(contentsOf: c.utf8)
                    i = line.index(after: i)
                }
            } else {
                // Regular character - convert to UTF-8 bytes
                bytes.append(contentsOf: c.utf8)
                i = line.index(after: i)
            }
        }
        
        // ✅ Dekodiere mit UTF-8
        let data = Data(bytes)
        var result = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        
        // Füge Newline hinzu (wenn nicht Soft Break)
        if !line.hasSuffix("=") {
            result += "\n"
        }
        
        return result
    }
    
    // MARK: - Charset Conversion
    
    private func applyCharsetConversion(data: Data, charset: String, warnings: inout [String]) throws -> String {
        let encoding: String.Encoding
        
        switch charset.lowercased() {
        case "utf-8":
            encoding = .utf8
        case "iso-8859-1", "latin-1":
            encoding = .isoLatin1
        case "windows-1252":
            encoding = .windowsCP1252
        case "ascii", "us-ascii":
            encoding = .ascii
        default:
            warnings.append("Unsupported charset \(charset), using UTF-8")
            print("MailProcessor Warning: Unsupported charset \(charset)")
            encoding = .utf8
        }
        
        guard let string = String(data: data, encoding: encoding) else {
            warnings.append("Charset conversion failed for \(charset)")
            print("MailProcessor Error: Charset conversion failed for \(charset)")
            return String(data: data, encoding: .utf8) ?? ""
        }
        
        return string
    }
    
    // MARK: - Content Structure Processing
    
    private func detectContentType(from rawData: String) -> String {
        if rawData.contains("Content-Type: text/html") {
            return "text/html"
        }
        if rawData.contains("Content-Type: multipart/alternative") {
            return "multipart/alternative"
        }
        if rawData.contains("Content-Type: multipart/mixed") {
            return "multipart/mixed"
        }
        return "text/plain"
    }
    
    private func extractContentParts(
        content: String,
        contentType: String,
        isMultipart: Bool,
        warnings: inout [String]
    ) throws -> (text: String?, html: String?, attachments: [ProcessedAttachment]) {
        
        if isMultipart {
            return try parseMultipartContent(content: content, contentType: contentType, warnings: &warnings)
        } else {
            if contentType.contains("text/html") {
                return (text: nil, html: content, attachments: [])
            } else {
                return (text: content, html: nil, attachments: [])
            }
        }
    }
    
    private func parseMultipartContent(
        content: String,
        contentType: String,
        warnings: inout [String]
    ) throws -> (text: String?, html: String?, attachments: [ProcessedAttachment]) {
        
        guard let boundary = extractBoundary(from: contentType) else {
            warnings.append("Multipart boundary not found")
            print("MailProcessor Warning: Multipart boundary not found")
            return (text: content, html: nil, attachments: [])
        }
        
        let parts = content.components(separatedBy: "--\(boundary)")
        var textPart: String?
        var htmlPart: String?
        var attachments: [ProcessedAttachment] = []
        
        for (index, part) in parts.enumerated() {
            if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            
            let (partContentType, partContent) = extractPartContent(part)
            
            if partContentType.contains("text/plain") {
                textPart = partContent
            } else if partContentType.contains("text/html") {
                htmlPart = partContent
            } else if partContentType.contains("application/") || partContentType.contains("image/") {
                if let attachment = createAttachment(from: part, partId: String(index)) {
                    attachments.append(attachment)
                }
            }
        }
        
        return (text: textPart, html: htmlPart, attachments: attachments)
    }
    
    private func extractBoundary(from contentType: String) -> String? {
        let pattern = #"boundary="?([^";\s]+)"?"#
        if let match = contentType.range(of: pattern, options: .regularExpression) {
            return String(contentType[match])
                .replacingOccurrences(of: "boundary=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
    
    private func extractPartContent(_ part: String) -> (contentType: String, content: String) {
        let lines = part.components(separatedBy: .newlines)
        var contentType = "text/plain"
        var contentStart = 0
        
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                contentStart = index + 1
                break
            }
            if line.lowercased().hasPrefix("content-type:") {
                contentType = line.replacingOccurrences(of: "Content-Type:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let content = lines.dropFirst(contentStart).joined(separator: "\n")
        return (contentType: contentType, content: content)
    }
    
    private func createAttachment(from part: String, partId: String) -> ProcessedAttachment? {
        let (contentType, content) = extractPartContent(part)
        let filename = extractFilename(from: part) ?? "attachment_\(partId)"
        
        guard let data = content.data(using: .utf8) else {
            print("MailProcessor Error: Failed to create attachment data for \(filename)")
            return nil
        }
        
        return ProcessedAttachment(
            filename: filename,
            mimeType: contentType,
            data: data,
            partId: partId
        )
    }
    
    private func extractFilename(from part: String) -> String? {
        let pattern = #"filename="?([^";]+)"?"#
        if let match = part.range(of: pattern, options: .regularExpression) {
            return String(part[match])
                .replacingOccurrences(of: "filename=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}

// MARK: - Legacy Compatibility

/// Static methods for legacy compatibility
public enum MailProcessorLegacy {
    
    /// Main processing entry point
    public static func processRawMail(_ rawData: String) async -> ProcessedMail {
        let processor = MailProcessor()
        do {
            return try await processor.processMailContent(
                rawData: rawData, 
                detectedCharset: nil, 
                detectedEncoding: nil, 
                contentType: nil
            )
        } catch {
            print("MailProcessor Error: Processing failed: \(error.localizedDescription)")
            return ProcessedMail(
                text: "Processing failed: \(error.localizedDescription)",
                html: nil,
                contentType: "text/plain",
                charset: "utf-8",
                transferEncoding: "7bit",
                isMultipart: false,
                rawSize: rawData.count,
                warnings: ["Processing failed: \(error.localizedDescription)"]
            )
        }
    }
}