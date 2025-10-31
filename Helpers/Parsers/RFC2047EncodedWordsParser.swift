// RFC2047EncodedWordsParser.swift - RFC2047 encoded-words decoder for email headers
import Foundation

/// RFC2047 encoded-words parser for email headers like Subject, From, To
/// Handles pattern: =?charset?encoding?data?=
public class RFC2047EncodedWordsParser {
    
    /// Encoding types supported by RFC2047
    public enum EncodingType: String, CaseIterable {
        case base64 = "B"
        case quotedPrintable = "Q"
        
        /// Create from string with case-insensitive matching
        static func from(_ string: String) -> EncodingType? {
            let normalized = string.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return EncodingType(rawValue: normalized)
        }
    }
    
    /// Represents a parsed encoded-word
    public struct EncodedWord {
        let charset: String
        let encoding: EncodingType
        let data: String
        let originalString: String
        
        /// Decode this encoded word to readable text
        func decode() -> String? {
            switch encoding {
            case .base64:
                return decodeBase64Data(data, charset: charset)
            case .quotedPrintable:
                return decodeQEncodedData(data, charset: charset)
            }
        }
    }
    
    /// Main entry point: decode all encoded-words in a string
    public static func decode(_ input: String) -> String {
        // RFC2047 pattern: =?charset?encoding?data?=
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, options: [], range: range)
        
        // Process matches from end to beginning to preserve string indices
        var result = input
        
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let charsetRange = Range(match.range(at: 1), in: result),
                  let encodingRange = Range(match.range(at: 2), in: result),
                  let dataRange = Range(match.range(at: 3), in: result) else {
                continue
            }
            
            let charset = String(result[charsetRange])
            let encodingStr = String(result[encodingRange])
            let data = String(result[dataRange])
            let originalString = String(result[fullRange])
            
            guard let encoding = EncodingType.from(encodingStr) else {
                continue
            }
            
            let encodedWord = EncodedWord(
                charset: charset,
                encoding: encoding,
                data: data,
                originalString: originalString
            )
            
            if let decoded = encodedWord.decode() {
                result.replaceSubrange(fullRange, with: decoded)
            }
        }
        
        // Clean up multiple consecutive spaces that might result from decoding
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Decode multiple encoded-words that might be adjacent
    public static func decodeMultiple(_ input: String) -> String {
        var result = input
        var previousLength: Int
        
        // Keep decoding until no more changes (handles nested/adjacent encoded-words)
        repeat {
            previousLength = result.count
            result = decode(result)
        } while result.count != previousLength
        
        return result
    }
    
    /// Decode Base64 data with charset conversion
    private static func decodeBase64Data(_ data: String, charset: String) -> String? {
        // Clean up base64 data (remove any whitespace)
        let cleanData = data.replacingOccurrences(of: " ", with: "")
        
        guard let decodedData = Data(base64Encoded: cleanData) else {
            return nil
        }
        
        // Convert using CharsetConverter
        return CharsetConverter.convert(data: decodedData, from: charset)
    }
    
    /// Decode Q-Encoding data (modified quoted-printable for headers)
    private static func decodeQEncodedData(_ data: String, charset: String) -> String? {
        // Q-encoding is like quoted-printable but with these differences:
        // 1. Spaces are encoded as underscores
        // 2. Only specific characters need to be encoded
        
        var decoded = data
        
        // Step 1: Replace underscores with spaces
        decoded = decoded.replacingOccurrences(of: "_", with: " ")
        
        // Step 2: Decode =XX hex sequences
        decoded = decodeQEncodingHexSequences(decoded)
        
        // Step 3: Convert charset
        guard let decodedData = decoded.data(using: .utf8) else {
            return decoded
        }
        
        return CharsetConverter.convert(data: decodedData, from: charset) ?? decoded
    }
    
    /// Decode hex sequences in Q-encoding
    private static func decodeQEncodingHexSequences(_ input: String) -> String {
        let pattern = "=([0-9A-Fa-f]{2})"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return input
        }
        
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = regex.matches(in: input, options: [], range: range)
        
        var result = input
        
        // Process matches from end to beginning
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            
            let hexString = String(result[hexRange])
            
            if let byte = UInt8(hexString, radix: 16) {
                let character = String(Character(UnicodeScalar(byte)))
                result.replaceSubrange(fullRange, with: character)
            }
        }
        
        return result
    }
    
    /// Check if string contains encoded-words
    public static func containsEncodedWords(_ input: String) -> Bool {
        let pattern = "=\\?[^?]+\\?[BbQq]\\?[^?]*\\?="
        return input.range(of: pattern, options: .regularExpression) != nil
    }
    
    /// Encode string as RFC2047 encoded-word (for completeness)
    public static func encode(_ text: String, charset: String = "utf-8", encoding: EncodingType = .base64) -> String {
        guard let data = text.data(using: .utf8) else {
            return text
        }
        
        let encodedData: String
        
        switch encoding {
        case .base64:
            encodedData = data.base64EncodedString()
        case .quotedPrintable:
            // For Q-encoding: encode special chars and replace spaces with underscores
            encodedData = encodeQEncoding(text)
        }
        
        return "=?\(charset)?\(encoding.rawValue)?\(encodedData)?="
    }
    
    /// Encode text using Q-encoding rules
    private static func encodeQEncoding(_ text: String) -> String {
        var result = ""
        
        for char in text {
            if char == " " {
                result += "_"
            } else if char.isASCII && char.asciiValue! < 128 && 
                      !["=", "?", "_"].contains(String(char)) {
                result += String(char)
            } else if let asciiValue = char.asciiValue {
                result += String(format: "=%02X", asciiValue)
            } else {
                // Unicode character - encode as UTF-8 bytes
                let utf8Data = String(char).data(using: .utf8) ?? Data()
                for byte in utf8Data {
                    result += String(format: "=%02X", byte)
                }
            }
        }
        
        return result
    }
    
    /// Test method for validation
    public static func test() {
        print("🧪 Testing RFC2047EncodedWordsParser...")
        
        // Test Base64 encoding
        let base64Test = "=?UTF-8?B?Q2Fmw6kgaW4gTcO8bmNoZW4=?="
        let base64Result = decode(base64Test)
        print("Base64: '\(base64Test)' → '\(base64Result)'")
        
        // Test Q-encoding
        let qEncodingTest = "=?ISO-8859-1?Q?Caf=E9_in_M=FCnchen?="
        let qResult = decode(qEncodingTest)
        print("Q-Encoding: '\(qEncodingTest)' → '\(qResult)'")
        
        // Test multiple encoded-words
        let multipleTest = "=?UTF-8?B?SGVsbG8=?= =?UTF-8?B?V29ybGQ=?="
        let multipleResult = decodeMultiple(multipleTest)
        print("Multiple: '\(multipleTest)' → '\(multipleResult)'")
        
        // Test mixed content
        let mixedTest = "Subject: =?UTF-8?Q?Re:_Caf=C3=A9_Meeting?= - Important"
        let mixedResult = decode(mixedTest)
        print("Mixed: '\(mixedTest)' → '\(mixedResult)'")
        
        // Test encoding (roundtrip)
        let originalText = "Café in München"
        let encoded = encode(originalText)
        let decoded = decode(encoded)
        print("Roundtrip: '\(originalText)' → '\(encoded)' → '\(decoded)'")
        
        print("✅ RFC2047EncodedWordsParser tests completed")
    }
}

/// Extension for email header processing
extension RFC2047EncodedWordsParser {
    
    /// Decode email subject line
    public static func decodeSubject(_ subject: String) -> String {
        return decodeMultiple(subject)
    }
    
    /// Decode email address with display name
    public static func decodeEmailAddress(_ address: String) -> String {
        // Handle format: "=?charset?encoding?Name?=" <email@domain.com>
        // or: "Name" <email@domain.com>
        return decodeMultiple(address)
    }
    
    /// Decode From header
    public static func decodeFrom(_ from: String) -> String {
        return decodeEmailAddress(from)
    }
    
    /// Decode To header (may contain multiple addresses)
    public static func decodeTo(_ to: String) -> String {
        // Split by comma, decode each part, then rejoin
        let addresses = to.components(separatedBy: ",")
        let decodedAddresses = addresses.map { address in
            decodeEmailAddress(address.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decodedAddresses.joined(separator: ", ")
    }
    
    /// Decode any email header that might contain encoded-words
    public static func decodeHeader(_ header: String) -> String {
        return decodeMultiple(header)
    }
}