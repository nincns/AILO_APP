// QuotedPrintableDecoder.swift - Universal Quoted-Printable decoder with charset support
import Foundation

/// Universal Quoted-Printable decoder that handles various character encodings
public class QuotedPrintableDecoder {
    
    /// Supported character encodings for decoding
    public enum SupportedCharset {
        case utf8
        case latin1       // ISO-8859-1
        case windows1252  // Windows-1252
        case unknown
        
        var encoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .latin1: return .isoLatin1
            case .windows1252: return .windowsCP1252
            case .unknown: return .isoLatin1 // Default fallback
            }
        }
    }
    
    /// Decode quoted-printable content with automatic charset detection
    public static func decode(_ content: String, charset: String? = nil) -> String {
        // Step 1: Detect charset
        let detectedCharset = detectCharset(charset)
        
        // Step 2: Remove soft line breaks
        let withoutSoftBreaks = removeSoftLineBreaks(content)
        
        // Step 3: Decode hex sequences to bytes
        let bytes = decodeHexSequences(withoutSoftBreaks)
        
        // Step 4: Convert bytes to string with appropriate encoding
        return bytesToString(bytes, charset: detectedCharset)
    }
    
    /// Remove soft line breaks (=\r\n, =\n)
    private static func removeSoftLineBreaks(_ content: String) -> String {
        var result = content
        
        // Remove quoted-printable soft line breaks
        result = result.replacingOccurrences(of: "=\r\n", with: "")
        result = result.replacingOccurrences(of: "=\n", with: "")
        
        return result
    }
    
    /// Decode all =XX hex sequences to byte array
    private static func decodeHexSequences(_ content: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = content.startIndex
        
        while index < content.endIndex {
            let char = content[index]
            
            if char == "=" {
                // Try to decode hex sequence
                if let (byte, newIndex) = decodeHexAtIndex(content, startIndex: index) {
                    bytes.append(byte)
                    index = newIndex
                } else {
                    // Not a valid hex sequence, keep the = character
                    bytes.append(UInt8(ascii: "="))
                    index = content.index(after: index)
                }
            } else {
                // Regular character - convert to UTF-8 bytes
                if let asciiValue = char.asciiValue {
                    bytes.append(asciiValue)
                } else {
                    // Non-ASCII character, encode as UTF-8
                    let charString = String(char)
                    bytes.append(contentsOf: charString.utf8)
                }
                index = content.index(after: index)
            }
        }
        
        return bytes
    }
    
    /// Decode hex sequence starting with = at given index
    private static func decodeHexAtIndex(_ content: String, startIndex: String.Index) -> (UInt8, String.Index)? {
        // Need at least 3 characters: =XX
        let next1 = content.index(after: startIndex)
        guard next1 < content.endIndex else { return nil }
        
        let next2 = content.index(after: next1)
        guard next2 < content.endIndex else { return nil }
        
        // Extract hex digits
        let hex1 = content[next1]
        let hex2 = content[next2]
        
        // Validate hex digits
        guard hex1.isHexDigit && hex2.isHexDigit else { return nil }
        
        // Convert to byte
        let hexString = String(hex1) + String(hex2)
        guard let byte = UInt8(hexString, radix: 16) else { return nil }
        
        return (byte, content.index(after: next2))
    }
    
    /// Convert byte array to string using specified charset
    private static func bytesToString(_ bytes: [UInt8], charset: SupportedCharset) -> String {
        let data = Data(bytes)
        
        // Try primary encoding first
        if let decoded = String(data: data, encoding: charset.encoding) {
            return decoded
        }
        
        // Fallback chain for robust decoding
        let fallbackEncodings: [String.Encoding] = [.isoLatin1, .utf8, .windowsCP1252]
        
        for encoding in fallbackEncodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        
        // Last resort: lossy UTF-8 conversion
        return String(data: data, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }
    
    /// Detect charset from string
    private static func detectCharset(_ charset: String?) -> SupportedCharset {
        guard let charset = charset?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .latin1 // Default for QP
        }
        
        // Normalize common charset variations
        let normalizedCharset: String
        switch charset {
        case "utf-8", "utf8":
            normalizedCharset = "utf-8"
        case "iso-8859-1", "latin-1", "latin1":
            normalizedCharset = "iso-8859-1"
        case "windows-1252", "cp1252", "windows1252":
            normalizedCharset = "windows-1252"
        default:
            // Try to handle other common variations
            if charset.contains("utf") {
                normalizedCharset = "utf-8"
            } else if charset.contains("1252") || charset.contains("cp1252") {
                normalizedCharset = "windows-1252"
            } else {
                normalizedCharset = "iso-8859-1" // Safe fallback
            }
        }
        
        switch normalizedCharset {
        case "utf-8": return .utf8
        case "iso-8859-1": return .latin1
        case "windows-1252": return .windows1252
        default: return .latin1 // Default for QP
        }
    }
}

// Extension for hex digit validation
extension Character {
    var isHexDigit: Bool {
        return self.isNumber || ("A"..."F").contains(self.uppercased().first!)
    }
}