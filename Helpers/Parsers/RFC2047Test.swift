// RFC2047Test.swift - Test file to validate RFC2047 subject decoding fix
import Foundation

/// Simple test to validate the RFC2047 fix
public class RFC2047Test {
    
    public static func testSubjectDecoding() {
        print("🧪 Testing RFC2047 Subject Decoding Fix...")
        
        // Test case from the user's problem
        let encodedSubject = "=?utf-8?Q?NANOQ=20=2D=20Ending=20In=2048H=21?="
        let expectedDecoded = "NANOQ - Ending In 48H!"
        
        let decoded = RFC2047EncodedWordsParser.decodeSubject(encodedSubject)
        
        print("📧 Original: '\(encodedSubject)'")
        print("📧 Decoded:  '\(decoded)'")
        print("📧 Expected: '\(expectedDecoded)'")
        
        if decoded == expectedDecoded {
            print("✅ RFC2047 Subject Decoding Test PASSED")
        } else {
            print("❌ RFC2047 Subject Decoding Test FAILED")
            print("   Expected: '\(expectedDecoded)'")
            print("   Got:      '\(decoded)'")
        }
        
        // Test a few more common cases
        testAdditionalCases()
        
        print("🎯 RFC2047 Subject Decoding Test Complete")
    }
    
    private static func testAdditionalCases() {
        print("\n🔍 Testing Additional RFC2047 Cases...")
        
        let testCases = [
            // Q-Encoding tests
            ("=?UTF-8?Q?Caf=C3=A9_Meeting?=", "Café Meeting"),
            ("=?ISO-8859-1?Q?Caf=E9_in_M=FCnchen?=", "Café in München"),
            ("=?utf-8?Q?Re:_Important_=E2=9C=85_Update?=", "Re: Important ✅ Update"),
            
            // Base64 encoding tests
            ("=?UTF-8?B?SGVsbG8gV29ybGQ=?=", "Hello World"),
            ("=?UTF-8?B?Q2Fmw6kgZW4gUGFyaXM=?=", "Café en Paris"),
            
            // Multiple encoded words
            ("=?UTF-8?B?SGVsbG8=?= =?UTF-8?B?V29ybGQ=?=", "Hello World"),
            
            // Mixed content
            ("Subject: =?UTF-8?Q?Meeting_=E2=9D=A4?= Tomorrow", "Subject: Meeting ❤ Tomorrow")
        ]
        
        for (encoded, expected) in testCases {
            let decoded = RFC2047EncodedWordsParser.decodeSubject(encoded)
            let status = decoded == expected ? "✅" : "❌"
            print("\(status) '\(encoded)' → '\(decoded)'")
            if decoded != expected {
                print("    Expected: '\(expected)'")
            }
        }
    }
    
    public static func testIMAPParserIntegration() {
        print("\n🔧 Testing IMAP Parser Integration...")
        
        // Simulate an IMAP ENVELOPE response with encoded subject
        let mockIMAPLine = "* 1 FETCH (UID 123 ENVELOPE (\"01-Jan-2024 10:00:00 +0000\" \"=?utf-8?Q?NANOQ=20=2D=20Ending=20In=2048H=21?=\" ((\"Sender Name\" NIL \"sender\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))"
        
        let parser = IMAPParsers()
        let results = parser.parseEnvelope([mockIMAPLine])
        
        if let result = results.first {
            print("📧 Parsed Subject: '\(result.subject)'")
            print("📧 Expected: 'NANOQ - Ending In 48H!'")
            
            if result.subject == "NANOQ - Ending In 48H!" {
                print("✅ IMAP Parser Integration Test PASSED")
            } else {
                print("❌ IMAP Parser Integration Test FAILED")
            }
        } else {
            print("❌ IMAP Parser Integration Test FAILED - No results")
        }
    }
}