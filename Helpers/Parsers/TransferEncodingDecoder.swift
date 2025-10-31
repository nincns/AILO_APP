// TransferEncodingDecoder.swift - Universal transfer encoding decoder
import Foundation

/// Universal decoder for email transfer encodings (quoted-printable, base64, etc.)
public class TransferEncodingDecoder {
    
    /// Decode content based on transfer encoding
    public static func decode(_ content: String, encoding: String?, charset: String?) -> String {
        guard let transferEncoding = encoding?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            // No encoding specified, return content as-is
            return content
        }
        
        switch transferEncoding {
        case "quoted-printable":
            return QuotedPrintableDecoder.decode(content, charset: charset)
            
        case "base64":
            return decodeBase64(content, charset: charset)
            
        case "7bit", "8bit", "binary":
            // No decoding needed for these encodings
            return content
            
        default:
            // Unknown encoding, try to decode anyway
            print("⚠️ WARNING: Unknown transfer encoding '\(transferEncoding)', returning content as-is")
            return content
        }
    }
    
    /// Decode Base64 content with charset handling
    private static func decodeBase64(_ content: String, charset: String?) -> String {
        // Clean up Base64 content (remove whitespace, newlines)
        let cleanedContent = content.components(separatedBy: .whitespacesAndNewlines).joined()
        
        // Decode Base64
        guard let data = Data(base64Encoded: cleanedContent) else {
            print("⚠️ WARNING: Invalid Base64 content")
            return content // Return original if decoding fails
        }
        
        // Convert to string with appropriate charset
        let detectedCharset = detectCharsetEncoding(charset)
        
        // Try primary encoding first
        if let decoded = String(data: data, encoding: detectedCharset) {
            return decoded
        }
        
        // Fallback to other encodings
        let fallbackEncodings: [String.Encoding] = [.utf8, .isoLatin1, .windowsCP1252]
        
        for encoding in fallbackEncodings {
            if let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        
        // Last resort: lossy UTF-8
        return String(data: data, encoding: .utf8) ?? content
    }
    
    /// Convert charset string to Swift String.Encoding
    private static func detectCharsetEncoding(_ charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .utf8 // Default
        }
        
        switch charset {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "latin-1", "latin1":
            return .isoLatin1
        case "windows-1252", "cp1252", "windows1252":
            return .windowsCP1252
        case "us-ascii", "ascii":
            return .ascii
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            // Try to handle common variations
            if charset.contains("utf") {
                return .utf8
            } else if charset.contains("1252") {
                return .windowsCP1252
            } else if charset.contains("8859") || charset.contains("latin") {
                return .isoLatin1
            } else {
                return .utf8 // Safe fallback
            }
        }
    }
    
    /// Test method to validate decoding
    public static func test() {
        print("🧪 Testing TransferEncodingDecoder...")
        
        // Test Quoted-Printable
        let qpTest = "This is a test with =E4 umlaut."
        let qpDecoded = decode(qpTest, encoding: "quoted-printable", charset: "iso-8859-1")
        print("QP Test: '\(qpTest)' -> '\(qpDecoded)'")
        
        // Test Base64
        let base64Test = "VGhpcyBpcyBhIHRlc3Q=" // "This is a test"
        let base64Decoded = decode(base64Test, encoding: "base64", charset: "utf-8")
        print("Base64 Test: '\(base64Test)' -> '\(base64Decoded)'")
        
        // Test no encoding
        let plainTest = "Plain text content"
        let plainDecoded = decode(plainTest, encoding: nil, charset: nil)
        print("Plain Test: '\(plainTest)' -> '\(plainDecoded)'")
        
        print("✅ TransferEncodingDecoder tests completed")
    }
}