// AttachmentSecurityService.swift
// Sicherheitsprüfungen für Email-Attachments

import Foundation
import CryptoKit

// MARK: - Attachment Security Service

class AttachmentSecurityService {
    
    // Security limits
    private let maxFileSize = 100 * 1024 * 1024  // 100 MB
    private let maxDecompressionRatio = 100      // Max 100:1 compression ratio
    private let maxNestedArchives = 3            // Max nesting depth
    
    // Dangerous file extensions
    private let dangerousExtensions = [
        "exe", "scr", "vbs", "js", "cmd", "bat", "com", "pif",
        "jar", "app", "dmg", "pkg", "deb", "rpm"
    ]
    
    // MARK: - Scan Attachment
    
    func scanAttachment(_ data: Data) async throws {
        // Check file size
        if data.count > maxFileSize {
            throw SecurityError.fileTooLarge(size: data.count)
        }
        
        // Check for zip bombs
        if isCompressedFile(data) {
            try await checkForZipBomb(data)
        }
        
        // Check file type
        let fileType = detectFileType(data)
        if isDangerousType(fileType) {
            throw SecurityError.dangerousFileType(type: fileType)
        }
        
        // Virus scan (if available)
        if let scanResult = try? await performVirusScan(data) {
            if !scanResult.isClean {
                throw SecurityError.virusDetected(name: scanResult.virusName)
            }
        }
    }
    
    // MARK: - Zip Bomb Detection
    
    private func checkForZipBomb(_ data: Data) async throws {
        // Simple check: compare compressed vs uncompressed size
        guard let uncompressedSize = getUncompressedSize(data) else {
            return
        }
        
        let ratio = uncompressedSize / data.count
        
        if ratio > maxDecompressionRatio {
            throw SecurityError.suspiciousCompression(ratio: ratio)
        }
        
        // Check for nested archives
        let nestingLevel = try detectNestingLevel(data)
        if nestingLevel > maxNestedArchives {
            throw SecurityError.excessiveNesting(level: nestingLevel)
        }
    }
    
    // MARK: - File Type Detection
    
    private func detectFileType(_ data: Data) -> String {
        guard data.count >= 4 else { return "unknown" }
        
        let magic = data.prefix(4)
        
        // Check magic numbers
        if magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if magic.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return "zip" }
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21]) { return "rar" }
        if magic.starts(with: [0x1F, 0x8B]) { return "gzip" }
        if magic.starts(with: [0x42, 0x5A]) { return "bzip2" }
        if magic.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) { return "7z" }
        if magic.starts(with: [0x4D, 0x5A]) { return "exe" }
        if magic.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if magic.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if magic.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        
        return "unknown"
    }
    
    private func isCompressedFile(_ data: Data) -> Bool {
        let type = detectFileType(data)
        return ["zip", "rar", "gzip", "bzip2", "7z", "tar"].contains(type)
    }
    
    private func isDangerousType(_ type: String) -> Bool {
        return ["exe", "scr", "com"].contains(type)
    }
    
    // MARK: - Helper Methods
    
    private func getUncompressedSize(_ data: Data) -> Int? {
        // This would use actual decompression libraries
        // For now, return a placeholder
        return nil
    }
    
    private func detectNestingLevel(_ data: Data) throws -> Int {
        // Would recursively check for archives within archives
        return 0
    }
    
    private func performVirusScan(_ data: Data) async throws -> ScanResult {
        // Integration with ClamAV or similar
        // For now, return clean
        return ScanResult(isClean: true, virusName: nil)
    }
    
    // MARK: - Content Sniffing Protection
    
    func getMimeType(for filename: String, data: Data) -> String {
        // Don't trust file extension alone
        let detectedType = detectFileType(data)
        let extensionType = mimeTypeFromExtension(filename)
        
        // If mismatch, use safer option
        if detectedType == "exe" && extensionType != "application/octet-stream" {
            return "application/octet-stream"
        }
        
        return extensionType ?? "application/octet-stream"
    }
    
    private func mimeTypeFromExtension(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        
        let mimeTypes: [String: String] = [
            "pdf": "application/pdf",
            "doc": "application/msword",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xls": "application/vnd.ms-excel",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "gif": "image/gif",
            "txt": "text/plain",
            "html": "text/html",
            "zip": "application/zip"
        ]
        
        return mimeTypes[ext]
    }
}

// MARK: - Security Errors

enum SecurityError: Error {
    case fileTooLarge(size: Int)
    case dangerousFileType(type: String)
    case suspiciousCompression(ratio: Int)
    case excessiveNesting(level: Int)
    case virusDetected(name: String?)
    case invalidContent
}

// MARK: - Scan Result

struct ScanResult {
    let isClean: Bool
    let virusName: String?
}

// MARK: - File Sanitization

extension AttachmentSecurityService {
    
    /// Sanitize filename for safe storage
    func sanitizeFilename(_ filename: String) -> String {
        var sanitized = filename
        
        // Remove path traversal attempts
        sanitized = sanitized.replacingOccurrences(of: "../", with: "")
        sanitized = sanitized.replacingOccurrences(of: "..\\", with: "")
        
        // Remove dangerous characters
        let allowedCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_."))
        
        sanitized = sanitized.components(separatedBy: allowedCharacters.inverted)
            .joined(separator: "_")
        
        // Limit length
        if sanitized.count > 255 {
            let ext = (sanitized as NSString).pathExtension
            let base = String(sanitized.prefix(250 - ext.count))
            sanitized = "\(base).\(ext)"
        }
        
        // Add safe extension if dangerous
        let ext = (sanitized as NSString).pathExtension.lowercased()
        if dangerousExtensions.contains(ext) {
            sanitized += ".txt"
        }
        
        return sanitized.isEmpty ? "unnamed" : sanitized
    }
}
