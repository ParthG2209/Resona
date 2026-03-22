import Foundation
import Security

// MARK: - KeychainManager

/// Thin wrapper around the macOS Keychain for storing OAuth tokens securely.
enum KeychainManager {

    // MARK: - Save

    @discardableResult
    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        delete(forKey: key)

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     Constants.App.bundleIdentifier,
            kSecAttrAccount:     key,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.error("Keychain save failed for key '\(key)': \(status)")
        }
        return status == errSecSuccess
    }

    // MARK: - Read

    static func read(forKey key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     Constants.App.bundleIdentifier,
            kSecAttrAccount:     key,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return value
    }

    // MARK: - Delete

    @discardableResult
    static func delete(forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Constants.App.bundleIdentifier,
            kSecAttrAccount: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Clear All (Sign Out)

    static func clearAll() {
        let keys = [
            Constants.Spotify.Keychain.accessToken,
            Constants.Spotify.Keychain.refreshToken,
            Constants.Spotify.Keychain.tokenExpiry,
            Constants.AppleMusic.Keychain.userToken
        ]
        keys.forEach { delete(forKey: $0) }
    }
}
