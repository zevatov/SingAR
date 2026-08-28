import Foundation

/// Stores the user's API keys (BYOK - Bring Your Own Key) in UserDefaults.
/// Keys are stored locally on the user's machine.
enum SecretStore {

    private static let defaults = UserDefaults.standard
    private static let prefix = "secret."

    static func set(_ value: String, for account: String) {
        defaults.setValue(value, forKey: prefix + account)
        NotificationCenter.default.post(name: .secretStoreDidChange, object: account)
    }

    static func get(_ account: String) -> String? {
        let v = defaults.string(forKey: prefix + account)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    static func remove(_ account: String) {
        defaults.removeObject(forKey: prefix + account)
        NotificationCenter.default.post(name: .secretStoreDidChange, object: account)
    }

    /// Account identifiers.
    enum Account {
        /// Google AI Studio API key for Gemini 3.5 Transcribe (Primary & Free Tier).
        static let googleApiKey = "google_api_key"
        /// Optional OpenRouter key fallback.
        static let openrouterKey = "openrouter_key"
    }
}

extension Notification.Name {
    static let secretStoreDidChange = Notification.Name("SecretStoreDidChangeNotification")
}
