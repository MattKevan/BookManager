import Foundation
import Security

/// Keychain storage for remote-library basic-auth credentials, keyed per
/// library. Lets a passworded server reconnect without re-prompting.
enum RemoteCredentials {
    private static let service = "com.mattkevan.Stacks.remote-libraries"

    /// Stores (or replaces) the credentials for a library.
    @discardableResult
    static func save(username: String, password: String, for libraryID: UUID) -> Bool {
        delete(for: libraryID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: libraryID.uuidString,
            kSecValueData as String: Data("\(username)\n\(password)".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Loads stored credentials for a library, or nil when none are stored.
    static func load(for libraryID: UUID) -> (username: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: libraryID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = String(data: data, encoding: .utf8) else { return nil }
        let parts = payload.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Removes stored credentials for a library.
    static func delete(for libraryID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: libraryID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
