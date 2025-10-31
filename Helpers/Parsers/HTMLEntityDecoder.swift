// HTMLEntityDecoder.swift - Comprehensive HTML entity decoder
import Foundation

/// Decoder for HTML entities (named, numeric decimal, and numeric hexadecimal)
public class HTMLEntityDecoder {
    
    /// Standard HTML entities mapping
    private static let namedEntities: [String: String] = [
        // Basic HTML entities
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": "\"",
        "&apos;": "'",
        "&nbsp;": " ", // Non-breaking space
        
        // German umlauts (critical for German emails)
        "&auml;": "ä", "&Auml;": "Ä",
        "&ouml;": "ö", "&Ouml;": "Ö", 
        "&uuml;": "ü", "&Uuml;": "Ü",
        "&szlig;": "ß",
        
        // French characters
        "&agrave;": "à", "&Agrave;": "À",
        "&aacute;": "á", "&Aacute;": "Á",
        "&acirc;": "â", "&Acirc;": "Â",
        "&egrave;": "è", "&Egrave;": "È",
        "&eacute;": "é", "&Eacute;": "É",
        "&ecirc;": "ê", "&Ecirc;": "Ê",
        "&ccedil;": "ç", "&Ccedil;": "Ç",
        
        // Spanish characters
        "&ntilde;": "ñ", "&Ntilde;": "Ñ",
        
        // Common symbols
        "&copy;": "©",
        "&reg;": "®",
        "&trade;": "™",
        "&euro;": "€",
        "&pound;": "£",
        "&yen;": "¥",
        "&sect;": "§",
        "&para;": "¶",
        "&middot;": "·",
        "&bull;": "•",
        "&hellip;": "…",
        "&ndash;": "–",
        "&mdash;": "—",
        "&lsquo;": "'", "&rsquo;": "'",
        "&ldquo;": "\"", "&rdquo;": "\"",
        "&laquo;": "«", "&raquo;": "»",
        
        // Math and special symbols
        "&plusmn;": "±",
        "&times;": "×",
        "&divide;": "÷",
        "&deg;": "°",
        "&frac12;": "½",
        "&frac14;": "¼",
        "&frac34;": "¾",
        
        // Currency
        "&cent;": "¢",
        "&curren;": "¤"
    ]
    
    /// Decode all HTML entities in text
    public static func decode(_ text: String) -> String {
        var result = text
        
        // Step 1: Decode named entities
        result = decodeNamedEntities(result)
        
        // Step 2: Decode numeric decimal entities (&#123;)
        result = decodeNumericEntities(result)
        
        // Step 3: Decode numeric hexadecimal entities (&#xAB;)
        result = decodeHexEntities(result)
        
        return result
    }
    
    /// Decode standard named HTML entities
    private static func decodeNamedEntities(_ text: String) -> String {
        var result = text
        
        // Replace all known named entities
        for (entity, replacement) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        
        return result
    }
    
    /// Decode numeric decimal entities (&#123;)
    private static func decodeNumericEntities(_ text: String) -> String {
        let pattern = "&#(\\d+);"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        
        // Process matches from end to beginning to preserve string indices
        let matches = regex.matches(in: text, options: [], range: range).reversed()
        var result = text
        
        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let numberRange = Range(match.range(at: 1), in: result) else { continue }
            
            let numberString = String(result[numberRange])
            
            if let codePoint = Int(numberString),
               let unicode = UnicodeScalar(codePoint) {
                let character = String(Character(unicode))
                result.replaceSubrange(fullRange, with: character)
            }
        }
        
        return result
    }
    
    /// Decode numeric hexadecimal entities (&#xAB;)
    private static func decodeHexEntities(_ text: String) -> String {
        let pattern = "&#[xX]([0-9A-Fa-f]+);"
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        
        // Process matches from end to beginning to preserve string indices
        let matches = regex.matches(in: text, options: [], range: range).reversed()
        var result = text
        
        for match in matches {
            guard let fullRange = Range(match.range, in: result),
                  let hexRange = Range(match.range(at: 1), in: result) else { continue }
            
            let hexString = String(result[hexRange])
            
            if let codePoint = Int(hexString, radix: 16),
               let unicode = UnicodeScalar(codePoint) {
                let character = String(Character(unicode))
                result.replaceSubrange(fullRange, with: character)
            }
        }
        
        return result
    }
    
    /// Decode entities specifically for HTML content
    public static func decodeForHTML(_ htmlContent: String) -> String {
        // For HTML content, we want to be more selective
        // Don't decode structural HTML entities that should remain
        var result = htmlContent
        
        // Only decode content entities, not structural ones
        let contentOnlyEntities = namedEntities.filter { entity, _ in
            !["&lt;", "&gt;", "&amp;", "&quot;"].contains(entity)
        }
        
        for (entity, replacement) in contentOnlyEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        
        // Still decode numeric entities (they're always content)
        result = decodeNumericEntities(result)
        result = decodeHexEntities(result)
        
        return result
    }
    
    /// Decode entities for plain text (decode everything)
    public static func decodeForPlainText(_ plainText: String) -> String {
        return decode(plainText)
    }
    
    /// Test method for validation
    public static func test() {
        print("🧪 Testing HTMLEntityDecoder...")
        
        // Test named entities
        let namedTest = "Caf&eacute; &amp; M&uuml;nchen &ndash; &euro;15.99"
        let namedResult = decode(namedTest)
        print("Named: '\(namedTest)' → '\(namedResult)'")
        
        // Test numeric decimal entities
        let numericTest = "Hello &#228;&#246;&#252; World!"
        let numericResult = decode(numericTest)
        print("Numeric: '\(numericTest)' → '\(numericResult)'")
        
        // Test hex entities
        let hexTest = "German: &#xE4;&#xF6;&#xFC; (&#xDF;)"
        let hexResult = decode(hexTest)
        print("Hex: '\(hexTest)' → '\(hexResult)'")
        
        // Test HTML vs Plain text
        let htmlTest = "<p>Hello &auml; &lt;world&gt;</p>"
        let htmlResult = decodeForHTML(htmlTest)
        let plainResult = decodeForPlainText(htmlTest)
        print("HTML: '\(htmlTest)' → '\(htmlResult)'")
        print("Plain: '\(htmlTest)' → '\(plainResult)'")
        
        print("✅ HTMLEntityDecoder tests completed")
    }
}

/// Integration extension for existing content processing
extension HTMLEntityDecoder {
    
    /// Smart entity decoding based on content type
    public static func smartDecode(_ content: String, isHTML: Bool) -> String {
        if isHTML {
            return decodeForHTML(content)
        } else {
            return decodeForPlainText(content)
        }
    }
    
    /// Check if text contains HTML entities
    public static func containsEntities(_ text: String) -> Bool {
        // Quick check for common entity patterns
        return text.contains("&") && (
            text.contains("&amp;") || text.contains("&lt;") || text.contains("&gt;") ||
            text.contains("&quot;") || text.contains("&nbsp;") || 
            text.contains("&auml;") || text.contains("&ouml;") || text.contains("&uuml;") ||
            text.range(of: "&#\\d+;", options: .regularExpression) != nil ||
            text.range(of: "&#[xX][0-9A-Fa-f]+;", options: .regularExpression) != nil
        )
    }
}