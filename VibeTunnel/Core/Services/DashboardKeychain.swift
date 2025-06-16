import Foundation
import os
import Security

/// Service for managing dashboard password in keychain
@MainActor
final class DashboardKeychain {
    static let shared = DashboardKeychain()

    private let service = "sh.vibetunnel.vibetunnel"
    private let account = "dashboard-password"
    private let logger = Logger(subsystem: "sh.vibetunnel.vibetunnel", category: "DashboardKeychain")

    private init() {}

    /// Get the dashboard password from keychain
    func getPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else {
            logger.debug("No password found in keychain")
            return nil
        }

        logger.debug("Password retrieved from keychain")
        return password
    }

    /// Check if a password exists without retrieving it (won't trigger keychain prompt)
    func hasPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: false,
            kSecReturnData as String: false
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        return status == errSecSuccess
    }

    /// Set the dashboard password in keychain
    func setPassword(_ password: String) -> Bool {
        guard !password.isEmpty else {
            logger.warning("Attempted to set empty password")
            return false
        }

        guard let data = password.data(using: .utf8) else {
            logger.warning("Failed to convert password to UTF-8 data")
            return false
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        // Try to update first
        var status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            // Item doesn't exist, create it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        let success = status == errSecSuccess
        logger.info("Password \(success ? "saved to" : "failed to save to") keychain")
        return success
    }

    /// Delete the dashboard password from keychain
    func deletePassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        let success = status == errSecSuccess || status == errSecItemNotFound
        logger.info("Password \(success ? "deleted from" : "failed to delete from") keychain")
        return success
    }
}
