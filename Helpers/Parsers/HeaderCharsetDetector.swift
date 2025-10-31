// HeaderCharsetDetector.swift - Charset detection from email headers
import Foundation

/// Utility for detecting and extracting charset information from email headers
public class HeaderCharsetDetector {
    
    /// Extract charset from Content-Type header
    public static func extractCharset(from contentType: String?) -> String? {
        guard let contentType = contentType?.lowercased() else {
            return nil
        }
        
        // Look for charset parameter in Content-Type header
        // Examples:
        // "text/plain; charset=utf-8"
        // "text/html; charset=iso-8859-1; boundary=something"
        // "text/plain; charset=\"utf-8\""
        
        // Split by semicolons to find charset parameter
        let components = contentType.components(separatedBy: ";")
        
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("charset=") {
                var charset = String(trimmed.dropFirst(8)) // Remove "charset="
                
                // Remove quotes if present
                charset = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                charset = charset.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Normalize charset name
                return normalizeCharset(charset)
            }
        }
        
        return nil
    }
    
    /// Extract boundary from Content-Type header
    public static func extractBoundary(from contentType: String?) -> String? {
        guard let contentType = contentType?.lowercased() else {
            return nil
        }
        
        // Look for boundary parameter
        let components = contentType.components(separatedBy: ";")
        
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst(9)) // Remove "boundary="
                
                // Remove quotes if present
                boundary = boundary.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                boundary = boundary.trimmingCharacters(in: .whitespacesAndNewlines)
                
                return boundary
            }
        }
        
        return nil
    }
    
    /// Detect content type from header
    public static func extractContentType(from contentType: String?) -> String? {
        guard let contentType = contentType else {
            return nil
        }
        
        // Extract main content type (before first semicolon)
        let components = contentType.components(separatedBy: ";")
        return components.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    /// Check if content type indicates HTML
    public static func isHTMLContentType(_ contentType: String?) -> Bool {
        guard let contentType = extractContentType(from: contentType) else {
            return false
        }
        
        return contentType.contains("text/html")
    }
    
    /// Check if content type indicates plain text
    public static func isPlainTextContentType(_ contentType: String?) -> Bool {
        guard let contentType = extractContentType(from: contentType) else {
            return false
        }
        
        return contentType.contains("text/plain")
    }
    
    /// Check if content type indicates multipart
    public static func isMultipartContentType(_ contentType: String?) -> Bool {
        guard let contentType = extractContentType(from: contentType) else {
            return false
        }
        
        return contentType.hasPrefix("multipart/")
    }
    
    /// Normalize charset names to standard forms
    private static func normalizeCharset(_ charset: String) -> String {
        let lowercased = charset.lowercased()
        
        switch lowercased {
        // UTF-8 variants
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return "utf-8"
            
        // ISO-8859-1 variants
        case "iso-8859-1", "iso88591", "latin-1", "latin1", "l1", "cp819":
            return "iso-8859-1"
            
        // ISO-8859-15 variants
        case "iso-8859-15", "iso885915", "latin-9", "latin9", "l9":
            return "iso-8859-15"
            
        // Windows-1252 variants
        case "windows-1252", "win-1252", "cp1252", "ms-ansi":
            return "windows-1252"
            
        // UTF-16 variants
        case "utf-16", "utf16", "unicode":
            return "utf-16"
        case "utf-16be", "utf-16-be", "unicodebig":
            return "utf-16be"
        case "utf-16le", "utf-16-le", "unicodelittle":
            return "utf-16le"
            
        // ASCII variants
        case "us-ascii", "ascii", "ansi_x3.4-1968":
            return "us-ascii"
            
        // Mac Roman variants
        case "macroman", "mac-roman", "mac", "macintosh", "x-mac-roman":
            return "macroman"
            
        default:
            // Return as-is if no normalization rule found
            return charset
        }
    }
    
    /// Get default charset for content type if none specified
    public static func getDefaultCharset(for contentType: String?) -> String {
        guard let contentType = extractContentType(from: contentType) else {
            return "utf-8" // Safe default
        }
        
        switch contentType {
        case let type where type.hasPrefix("text/"):
            return "utf-8" // Modern default for text
        case let type where type.hasPrefix("application/"):
            return "utf-8" // Most applications expect UTF-8
        default:
            return "utf-8" // Safe default
        }
    }
    
    /// Test method to validate charset detection
    public static func test() {
        print("🧪 Testing HeaderCharsetDetector...")
        
        // Test charset extraction
        let testHeaders = [
            "text/plain; charset=utf-8",
            "text/html; charset=\"iso-8859-1\"; boundary=test",
            "text/plain; charset='windows-1252'",
            "multipart/alternative; boundary=test; charset=utf-8",
            "text/plain",
            nil
        ]
        
        for (index, header) in testHeaders.enumerated() {
            let charset = extractCharset(from: header)
            let contentType = extractContentType(from: header)
            let boundary = extractBoundary(from: header)
            
            print("Test \(index + 1):")
            print("  Input: '\(header ?? "nil")'")
            print("  Charset: '\(charset ?? "nil")'")
            print("  Content-Type: '\(contentType ?? "nil")'")
            print("  Boundary: '\(boundary ?? "nil")'")
            print("  Is HTML: \(isHTMLContentType(header))")
            print("  Is Multipart: \(isMultipartContentType(header))")
            print()
        }
        
        print("✅ HeaderCharsetDetector tests completed")
    }
}