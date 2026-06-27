import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing secrets (API keys,
/// subscription tokens). Nothing sensitive is ever written to UserDefaults
/// or the app binary.
///
/// Accounts used:
///   - "zenmux_key"       : user's own ZenMux API key (BYOK, LLM-polish)
///   - "openrouter_key"   : user's own OpenRouter API key (BYOK, re-ASR)
///   - "sub_token"        : subscription auth token issued by the SingAR proxy
enum KeychainStore {

    private static let service = "app.singar"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension KeychainStore {
    /// Account identifiers.
    enum Account {
        /// User's own ZenMux key (BYOK, LLM-polish).
        static let zenmuxKey = "zenmux_key"
        /// User's own OpenRouter key (BYOK, re-ASR).
        static let openrouterKey = "openrouter_key"
        /// Subscription token from the SingAR proxy (managed mode).
        static let subscriptionToken = "sub_token"
    }
}
