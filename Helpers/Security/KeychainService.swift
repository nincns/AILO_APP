import Foundation
import Security

/// A simple Keychain wrapper for storing and retrieving sensitive strings (passwords).
enum KeychainService {
    /// The kind of password stored in the Keychain.
    enum PasswordKind {
        case recv
        case smtp
        
        /// Returns the prefix part of the key used for this kind.
        fileprivate var keyPrefix: String {
            switch self {
            case .recv: return "mail.recv"
            case .smtp: return "mail.smtp"
            }
        }
    }
    
    enum TokenKind {
        case recv
        case smtp
        fileprivate var keyPrefix: String {
            switch self {
            case .recv: return "mail.oauth.recv"
            case .smtp: return "mail.oauth.smtp"
            }
        }
    }
    
    /// The service identifier used for the Keychain entries.
    private static let service = Bundle.main.bundleIdentifier ?? "mail.app"
    
    // MARK: - Public API
    
    /// Stores a password string in the Keychain for the given key.
    /// - Parameters:
    ///   - value: The string value to store.
    ///   - key: The account key for this item.
    /// - Returns: True if storing succeeded, false otherwise.
    static func set(_ value: String, for key: String) -> Bool {
        delete(key)
        
        guard let data = value.data(using: .utf8) else {
            return false
        }
        
        let query: [String: Any] = [
            kSecClass as String : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecAttrAccount as String : key,
            kSecValueData as String : data,
            kSecAttrAccessible as String : kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Retrieves a string value from the Keychain for the given key.
    /// - Parameter key: The account key to look up.
    /// - Returns: The stored string if found, nil otherwise.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecAttrAccount as String : key,
            kSecMatchLimit as String : kSecMatchLimitOne,
            kSecReturnData as String : true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return value
    }
    
    /// Deletes the Keychain item associated with the given key.
    /// - Parameter key: The account key for the item to delete.
    /// - Returns: True if deletion succeeded or item did not exist, false otherwise.
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String : kSecClassGenericPassword,
            kSecAttrService as String : service,
            kSecAttrAccount as String : key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Stores a password in the Keychain for a given password kind and account identifier.
    /// - Parameters:
    ///   - password: The optional password string to store. If nil, deletes the stored password.
    ///   - kind: The kind of password (recv or smtp).
    ///   - accountId: The UUID identifying the account.
    static func setPassword(_ password: String?, kind: PasswordKind, accountId: UUID) {
        let key = keyFor(kind: kind, accountId: accountId)
        if let pwd = password {
            _ = set(pwd, for: key)
        } else {
            _ = delete(key)
        }
    }
    
    /// Retrieves the password stored for the given kind and account identifier.
    /// - Parameters:
    ///   - kind: The kind of password (recv or smtp).
    ///   - accountId: The UUID identifying the account.
    /// - Returns: The stored password string if found, nil otherwise.
    static func password(kind: PasswordKind, accountId: UUID) -> String? {
        let key = keyFor(kind: kind, accountId: accountId)
        return get(key)
    }

    // MARK: - OAuth2 Token Storage
    static func setToken(_ token: String?, kind: TokenKind, accountId: UUID) {
        let key = "\(kind.keyPrefix).\(accountId.uuidString)"
        if let token {
            _ = set(token, for: key)
        } else {
            _ = delete(key)
        }
    }

    static func token(kind: TokenKind, accountId: UUID) -> String? {
        let key = "\(kind.keyPrefix).\(accountId.uuidString)"
        return get(key)
    }
    
    // MARK: - Private Helpers
    
    /// Constructs the key string used for storing/retrieving passwords of a given kind and account ID.
    /// - Parameters:
    ///   - kind: The kind of password.
    ///   - accountId: The UUID identifying the account.
    /// - Returns: The composite key string.
    private static func keyFor(kind: PasswordKind, accountId: UUID) -> String {
        return "\(kind.keyPrefix).\(accountId.uuidString)"
    }
}
