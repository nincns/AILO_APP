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
        warnings: inout [String],
        partPrefix: String = ""
    ) throws -> (text: String?, html: String?, attachments: [ProcessedAttachment]) {

        guard let boundary = extractBoundary(from: contentType) else {
            warnings.append("Multipart boundary not found in: \(contentType.prefix(50))")
            print("MailProcessor Warning: Multipart boundary not found")
            return (text: content, html: nil, attachments: [])
        }

        let parts = content.components(separatedBy: "--\(boundary)")
        var textPart: String?
        var htmlPart: String?
        var attachments: [ProcessedAttachment] = []

        print("📦 [MailProcessor] Found \(parts.count) parts with boundary: \(boundary.prefix(30))...")

        for (index, part) in parts.enumerated() {
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip empty parts and end boundary markers
            if trimmedPart.isEmpty || trimmedPart == "--" { continue }

            let partId = partPrefix.isEmpty ? String(index) : "\(partPrefix).\(index)"
            let partInfo = extractFullPartInfo(trimmedPart)

            print("   📝 Part \(partId): \(partInfo.contentType) (disposition: \(partInfo.contentDisposition ?? "none"))")

            // ✅ KRITISCHER FIX: Rekursive Verarbeitung verschachtelter Multiparts
            if partInfo.contentType.lowercased().contains("multipart/") {
                print("   🔁 Nested multipart detected, processing recursively...")

                let nestedResult = try parseMultipartContent(
                    content: partInfo.body,
                    contentType: partInfo.fullContentType,
                    warnings: &warnings,
                    partPrefix: partId
                )

                // Merge results (erste gefundene Werte behalten)
                if textPart == nil, let nestedText = nestedResult.text {
                    textPart = nestedText
                    print("   ✅ Merged nested text (\(nestedText.count) chars)")
                }
                if htmlPart == nil, let nestedHtml = nestedResult.html {
                    htmlPart = nestedHtml
                    print("   ✅ Merged nested HTML (\(nestedHtml.count) chars)")
                }
                attachments.append(contentsOf: nestedResult.attachments)
                continue
            }

            // Prüfe ob Part ein Attachment ist
            if isAttachmentPart(partInfo: partInfo) {
                if let attachment = createAttachment(from: trimmedPart, partId: partId, partInfo: partInfo) {
                    attachments.append(attachment)
                    print("   📎 Attachment created: \(attachment.filename) (\(attachment.sizeBytes) bytes)")
                }
                continue
            }

            // Verarbeite Body-Parts (text/plain, text/html)
            let decodedContent = decodePartContent(partInfo: partInfo)

            if partInfo.contentType.lowercased().contains("text/plain") {
                if textPart == nil {
                    textPart = decodedContent
                    print("   ✅ Text part decoded (\(decodedContent.count) chars)")
                }
            } else if partInfo.contentType.lowercased().contains("text/html") {
                if htmlPart == nil {
                    htmlPart = decodedContent
                    print("   ✅ HTML part decoded (\(decodedContent.count) chars)")
                }
            }
        }

        return (text: textPart, html: htmlPart, attachments: attachments)
    }

    // MARK: - Part Info Extraction

    private struct PartInfo {
        let contentType: String
        let fullContentType: String
        let transferEncoding: String
        let contentDisposition: String?
        let contentId: String?
        let filename: String?
        let charset: String?
        let body: String
        let headers: String
    }

    private func extractFullPartInfo(_ part: String) -> PartInfo {
        let lines = part.components(separatedBy: .newlines)
        var contentType = "text/plain"
        var fullContentType = "text/plain"
        var transferEncoding = "7bit"
        var contentDisposition: String?
        var contentId: String?
        var filename: String?
        var charset: String?
        var headerEndIndex = 0
        var headerLines: [String] = []

        // Parse headers
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                headerEndIndex = index + 1
                break
            }
            headerLines.append(line)

            let lowerLine = line.lowercased()

            if lowerLine.hasPrefix("content-type:") {
                fullContentType = String(line.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
                contentType = extractMimeType(from: fullContentType)
                charset = extractCharsetFromContentType(fullContentType)
            } else if lowerLine.hasPrefix("content-transfer-encoding:") {
                transferEncoding = String(line.dropFirst("content-transfer-encoding:".count)).trimmingCharacters(in: .whitespaces)
            } else if lowerLine.hasPrefix("content-disposition:") {
                contentDisposition = String(line.dropFirst("content-disposition:".count)).trimmingCharacters(in: .whitespaces)
                filename = extractFilenameFromDisposition(contentDisposition!)
            } else if lowerLine.hasPrefix("content-id:") {
                contentId = String(line.dropFirst("content-id:".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            }
        }

        // Extrahiere auch filename aus Content-Type falls nicht in Disposition
        if filename == nil {
            filename = extractFilename(from: part)
        }

        let body = lines.dropFirst(headerEndIndex).joined(separator: "\n")
        let headers = headerLines.joined(separator: "\n")

        return PartInfo(
            contentType: contentType,
            fullContentType: fullContentType,
            transferEncoding: transferEncoding,
            contentDisposition: contentDisposition,
            contentId: contentId,
            filename: filename,
            charset: charset,
            body: body,
            headers: headers
        )
    }

    private func extractMimeType(from contentType: String) -> String {
        // Extrahiere nur den MIME-Type ohne Parameter
        return contentType.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? contentType
    }

    private func extractCharsetFromContentType(_ contentType: String) -> String? {
        let pattern = #"charset="?([^";\s]+)"?"#
        if let match = contentType.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(contentType[match])
                .replacingOccurrences(of: "charset=", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    private func extractFilenameFromDisposition(_ disposition: String) -> String? {
        let pattern = #"filename="?([^";]+)"?"#
        if let match = disposition.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            return String(disposition[match])
                .replacingOccurrences(of: "filename=", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    // MARK: - Attachment Detection

    private func isAttachmentPart(partInfo: PartInfo) -> Bool {
        // Explizit als Attachment markiert
        if let disposition = partInfo.contentDisposition?.lowercased() {
            if disposition.contains("attachment") {
                return true
            }
        }

        // Content-Types die typischerweise Attachments sind
        let attachmentTypes = [
            "application/", "image/", "audio/", "video/"
        ]

        let lowerContentType = partInfo.contentType.lowercased()

        for attachmentType in attachmentTypes {
            if lowerContentType.hasPrefix(attachmentType) {
                // Ausnahme: inline images (haben Content-ID und inline disposition)
                if partInfo.contentId != nil && partInfo.contentDisposition?.lowercased().contains("inline") == true {
                    return false  // Inline image, nicht als separates Attachment behandeln
                }
                return true
            }
        }

        return false
    }

    // MARK: - Content Decoding

    private func decodePartContent(partInfo: PartInfo) -> String {
        let encoding = partInfo.transferEncoding.lowercased()
        let body = partInfo.body

        switch encoding {
        case "base64":
            let cleanBase64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: cleanBase64),
               let decoded = String(data: data, encoding: charsetToEncoding(partInfo.charset)) {
                return decoded
            }
            // Fallback zu UTF-8
            if let data = Data(base64Encoded: cleanBase64),
               let decoded = String(data: data, encoding: .utf8) {
                return decoded
            }
            return body

        case "quoted-printable":
            return decodeQuotedPrintableString(body)

        default:
            return body
        }
    }

    private func charsetToEncoding(_ charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased() else { return .utf8 }

        switch charset {
        case "utf-8": return .utf8
        case "iso-8859-1", "latin-1": return .isoLatin1
        case "windows-1252": return .windowsCP1252
        case "ascii", "us-ascii": return .ascii
        default: return .utf8
        }
    }

    private func decodeQuotedPrintableString(_ input: String) -> String {
        var result = ""
        let lines = input.components(separatedBy: .newlines)

        for line in lines {
            result += decodeQuotedPrintableLine(line)
        }

        return result
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

    /// Erstellt ein ProcessedAttachment mit korrekter Base64-Dekodierung
    private func createAttachment(from part: String, partId: String, partInfo: PartInfo) -> ProcessedAttachment? {
        let filename = partInfo.filename ?? "attachment_\(partId)"
        let mimeType = partInfo.contentType
        let encoding = partInfo.transferEncoding.lowercased()
        let body = partInfo.body

        print("   📎 [createAttachment] Creating: \(filename)")
        print("      - MIME: \(mimeType)")
        print("      - Encoding: \(encoding)")
        print("      - Body size: \(body.count) chars")

        let data: Data

        // ✅ KRITISCHER FIX: Korrekte Dekodierung basierend auf Transfer-Encoding
        switch encoding {
        case "base64":
            // Entferne Whitespace und dekodiere Base64
            let cleanBase64 = body.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let decoded = Data(base64Encoded: cleanBase64) else {
                print("   ⚠️ Base64 decoding failed for \(filename)")
                // Fallback: Verwende raw data
                guard let fallbackData = body.data(using: .utf8) else {
                    print("   ❌ Failed to create attachment data for \(filename)")
                    return nil
                }
                data = fallbackData
                break
            }
            data = decoded
            print("      ✅ Base64 decoded: \(decoded.count) bytes")

        case "quoted-printable":
            let decodedString = decodeQuotedPrintableString(body)
            guard let qpData = decodedString.data(using: .utf8) else {
                print("   ❌ QP decoding failed for \(filename)")
                return nil
            }
            data = qpData

        default:
            // 7bit, 8bit, binary - use as-is
            guard let rawData = body.data(using: .utf8) else {
                print("   ❌ Failed to create raw data for \(filename)")
                return nil
            }
            data = rawData
        }

        // Prüfe ob inline (hat Content-ID)
        let isInline = partInfo.contentId != nil ||
                      partInfo.contentDisposition?.lowercased().contains("inline") == true

        return ProcessedAttachment(
            filename: filename,
            mimeType: mimeType,
            data: data,
            contentId: partInfo.contentId,
            isInline: isInline,
            partId: partId
        )
    }

    /// Legacy-Version für Abwärtskompatibilität
    private func createAttachment(from part: String, partId: String) -> ProcessedAttachment? {
        let partInfo = extractFullPartInfo(part)
        return createAttachment(from: part, partId: partId, partInfo: partInfo)
    }

    private func extractFilename(from part: String) -> String? {
        // Zuerst in Content-Disposition suchen
        let dispositionPattern = #"filename="?([^";\r\n]+)"?"#
        if let match = part.range(of: dispositionPattern, options: [.regularExpression, .caseInsensitive]) {
            return String(part[match])
                .replacingOccurrences(of: "filename=", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        // Dann in Content-Type name= Parameter suchen
        let namePattern = #"name="?([^";\r\n]+)"?"#
        if let match = part.range(of: namePattern, options: [.regularExpression, .caseInsensitive]) {
            return String(part[match])
                .replacingOccurrences(of: "name=", with: "", options: .caseInsensitive)
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