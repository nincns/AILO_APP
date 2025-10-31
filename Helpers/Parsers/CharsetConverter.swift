// CharsetConverter.swift - Universal charset conversion and detection
import Foundation

/// Universal charset converter with automatic encoding detection and conversion
public class CharsetConverter {
    
    /// Supported charset encodings with priority order
    public enum SupportedCharset: CaseIterable {
        case utf8
        case latin1         // ISO-8859-1
        case latin9         // ISO-8859-15 (Euro support)
        case windows1252    // Windows-1252
        case utf16be        // UTF-16 Big Endian
        case utf16le        // UTF-16 Little Endian
        case macRoman       // Mac Roman (legacy Mac emails)
        case ascii          // Basic ASCII
        case utf32          // UTF-32 (rare but possible)
        
        /// Get Swift String.Encoding equivalent
        var encoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .latin1: return .isoLatin1
            case .latin9: return .isoLatin2 // Closest available
            case .windows1252: return .windowsCP1252
            case .utf16be: return .utf16BigEndian
            case .utf16le: return .utf16LittleEndian
            case .macRoman: return .macOSRoman
            case .ascii: return .ascii
            case .utf32: return .utf32
            }
        }
        
        /// Common names for this charset
        var aliases: [String] {
            switch self {
            case .utf8:
                return ["utf-8", "utf8", "unicode-1-1-utf-8"]
            case .latin1:
                return ["iso-8859-1", "iso88591", "latin1", "latin-1", "l1", "cp819"]
            case .latin9:
                return ["iso-8859-15", "iso885915", "latin9", "latin-9", "l9"]
            case .windows1252:
                return ["windows-1252", "win-1252", "cp1252", "ms-ansi"]
            case .utf16be:
                return ["utf-16be", "utf-16-be", "unicodebig", "unicode-1-1-utf-16be"]
            case .utf16le:
                return ["utf-16le", "utf-16-le", "unicodelittle", "unicode-1-1-utf-16le"]
            case .macRoman:
                return ["macroman", "mac-roman", "mac", "macintosh", "csmacintosh"]
            case .ascii:
                return ["ascii", "us-ascii", "ansi_x3.4-1968", "iso-ir-6"]
            case .utf32:
                return ["utf-32", "utf32"]
            }
        }
    }
    
    /// Convert data from one encoding to another
    public static func convert(data: Data, from sourceCharset: String?, to targetEncoding: String.Encoding = .utf8) -> String? {
        // Step 1: Determine source encoding
        let sourceEncoding = normalizeCharsetName(sourceCharset) ?? detectEncoding(from: data)
        
        // Step 2: Try to decode with detected/specified encoding
        if let decoded = String(data: data, encoding: sourceEncoding.encoding) {
            return decoded
        }
        
        // Step 3: Fallback chain if primary encoding fails
        let fallbackEncodings = getFallbackEncodings(for: sourceEncoding)
        
        for encoding in fallbackEncodings {
            if let decoded = String(data: data, encoding: encoding.encoding) {
                return decoded
            }
        }
        
        // Step 4: Last resort - lossy conversion
        return String(data: data, encoding: .utf8) ?? 
               String(data: data, encoding: .isoLatin1)
    }
    
    /// Detect encoding from raw data using heuristics
    public static func detectEncoding(from data: Data) -> SupportedCharset {
        // Check for BOM (Byte Order Mark)
        if let bomEncoding = detectBOM(from: data) {
            return bomEncoding
        }
        
        // Statistical analysis for text-based detection
        return detectByStatistics(data)
    }
    
    /// Detect BOM (Byte Order Mark) at beginning of data
    private static func detectBOM(from data: Data) -> SupportedCharset? {
        guard data.count >= 2 else { return nil }
        
        let bytes = Array(data.prefix(4))
        
        // UTF-8 BOM: EF BB BF
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return .utf8
        }
        
        // UTF-16 BE BOM: FE FF
        if bytes[0] == 0xFE && bytes[1] == 0xFF {
            return .utf16be
        }
        
        // UTF-16 LE BOM: FF FE
        if bytes[0] == 0xFF && bytes[1] == 0xFE {
            return .utf16le
        }
        
        // UTF-32 BE BOM: 00 00 FE FF
        if bytes.count >= 4 && bytes[0] == 0x00 && bytes[1] == 0x00 && 
           bytes[2] == 0xFE && bytes[3] == 0xFF {
            return .utf32
        }
        
        return nil
    }
    
    /// Detect encoding using statistical analysis
    private static func detectByStatistics(_ data: Data) -> SupportedCharset {
        let bytes = Array(data)
        
        // Check for UTF-8 multi-byte sequences
        if isValidUTF8(bytes) && hasUTF8MultibyteChars(bytes) {
            return .utf8
        }
        
        // Check for high-bit characters (suggests Latin-1/Windows-1252)
        let highBitCount = bytes.filter { $0 >= 0x80 }.count
        let totalBytes = bytes.count
        
        if totalBytes > 0 {
            let highBitRatio = Double(highBitCount) / Double(totalBytes)
            
            // If more than 5% high-bit chars, likely Latin-1 or Windows-1252
            if highBitRatio > 0.05 {
                // Check for Windows-1252 specific characters
                if hasWindows1252Chars(bytes) {
                    return .windows1252
                }
                return .latin1
            }
        }
        
        // Check for null bytes (suggests UTF-16)
        let nullCount = bytes.filter { $0 == 0x00 }.count
        if nullCount > 0 {
            // Even positions = UTF-16 LE, Odd positions = UTF-16 BE
            let evenNulls = bytes.enumerated().filter { $0.offset % 2 == 0 && $0.element == 0x00 }.count
            let oddNulls = bytes.enumerated().filter { $0.offset % 2 == 1 && $0.element == 0x00 }.count
            
            if evenNulls > oddNulls {
                return .utf16be
            } else if oddNulls > evenNulls {
                return .utf16le
            }
        }
        
        // Default: probably UTF-8 or ASCII
        return .utf8
    }
    
    /// Check if byte sequence is valid UTF-8
    private static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        
        while i < bytes.count {
            let byte = bytes[i]
            
            if byte < 0x80 {
                // ASCII character
                i += 1
            } else if byte < 0xC0 {
                // Invalid start byte
                return false
            } else if byte < 0xE0 {
                // 2-byte sequence
                if i + 1 >= bytes.count || bytes[i + 1] < 0x80 || bytes[i + 1] >= 0xC0 {
                    return false
                }
                i += 2
            } else if byte < 0xF0 {
                // 3-byte sequence
                if i + 2 >= bytes.count {
                    return false
                }
                for j in 1...2 {
                    if bytes[i + j] < 0x80 || bytes[i + j] >= 0xC0 {
                        return false
                    }
                }
                i += 3
            } else if byte < 0xF8 {
                // 4-byte sequence
                if i + 3 >= bytes.count {
                    return false
                }
                for j in 1...3 {
                    if bytes[i + j] < 0x80 || bytes[i + j] >= 0xC0 {
                        return false
                    }
                }
                i += 4
            } else {
                // Invalid byte
                return false
            }
        }
        
        return true
    }
    
    /// Check if data contains UTF-8 multi-byte characters
    private static func hasUTF8MultibyteChars(_ bytes: [UInt8]) -> Bool {
        return bytes.contains { $0 >= 0xC0 }
    }
    
    /// Check for Windows-1252 specific characters
    private static func hasWindows1252Chars(_ bytes: [UInt8]) -> Bool {
        // Characters that are defined in Windows-1252 but not in ISO-8859-1
        let windows1252Specific: [UInt8] = [
            0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8E,
            0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9E, 0x9F
        ]
        
        return bytes.contains { windows1252Specific.contains($0) }
    }
    
    /// Normalize charset name to SupportedCharset
    public static func normalizeCharsetName(_ name: String?) -> SupportedCharset? {
        guard let charset = name?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-") else {
            return nil
        }
        
        // Find matching charset by aliases
        for supportedCharset in SupportedCharset.allCases {
            if supportedCharset.aliases.contains(charset) {
                return supportedCharset
            }
        }
        
        return nil
    }
    
    /// Get fallback encodings for a given charset
    private static func getFallbackEncodings(for charset: SupportedCharset) -> [SupportedCharset] {
        switch charset {
        case .utf8:
            return [.latin1, .windows1252, .utf16le]
        case .latin1:
            return [.windows1252, .utf8, .latin9]
        case .latin9:
            return [.latin1, .windows1252, .utf8]
        case .windows1252:
            return [.latin1, .utf8, .latin9]
        case .utf16be:
            return [.utf16le, .utf8]
        case .utf16le:
            return [.utf16be, .utf8]
        case .macRoman:
            return [.latin1, .utf8]
        case .ascii:
            return [.utf8, .latin1]
        case .utf32:
            return [.utf8, .utf16le]
        }
    }
    
    /// Convert string to different charset (for testing)
    public static func convertString(_ text: String, to targetCharset: SupportedCharset) -> Data? {
        return text.data(using: targetCharset.encoding)
    }
}

/// Extension for email integration
extension CharsetConverter {
    
    /// Convert email content with charset detection
    public static func convertEmailContent(_ data: Data, declaredCharset: String? = nil) -> String? {
        // Try declared charset first
        if let declared = declaredCharset,
           let charset = normalizeCharsetName(declared),
           let converted = String(data: data, encoding: charset.encoding) {
            return converted
        }
        
        // Fallback to auto-detection
        return convert(data: data, from: declaredCharset)
    }
    
    /// Check if charset is supported
    public static func isSupported(_ charsetName: String) -> Bool {
        return normalizeCharsetName(charsetName) != nil
    }
    
    /// Get recommended charset for given data
    public static func recommendCharset(for data: Data) -> String {
        let detected = detectEncoding(from: data)
        return detected.aliases.first ?? "utf-8"
    }
}