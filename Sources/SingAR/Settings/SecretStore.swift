import Foundation
import Security

/// Stores the user's API keys (BYOK - Bring Your Own Key) in the macOS Keychain
/// (Security framework, generic password items scoped to this app's service name).
/// Keys never leave the user's Keychain. Legacy `secret.*` values previously
/// stored in UserDefaults are migrated to the Keychain once, on first read,
/// and removed from UserDefaults only after a read-back proves the Keychain
/// holds the exact same value (fail-safe against locked/failed writes).
enum SecretStore {

    private static let prefix = "secret."
    /// Service identifier for generic-password items. Falls back to a stable
    /// name when the bundle identifier is unavailable (e.g. bare `swift run`).
    private static let service = Bundle.main.bundleIdentifier ?? "SingAR"

    static func set(_ value: String, for account: String) {
        switch setAction(for: value) {
        case .remove:
            remove(account)
        case .upsert(let trimmed):
            let status = upsert(trimmed, account: keychainAccount(for: account))
            if status == errSecSuccess {
                // Belt-and-suspenders: drop any pre-migration leftover.
                clearLegacy(account)
                NotificationCenter.default.post(name: .secretStoreDidChange, object: account)
            }
        }
    }

    static func get(_ account: String) -> String? {
        if let stored = read(account: keychainAccount(for: account))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !stored.isEmpty {
            return stored
        }
        // Keychain miss: try a one-time migration from legacy UserDefaults.
        return migrateLegacy(account)
    }

    static func remove(_ account: String) {
        SecItemDelete(makeQuery(account: keychainAccount(for: account)) as CFDictionary)
        clearLegacy(account)
        NotificationCenter.default.post(name: .secretStoreDidChange, object: account)
    }

    /// Account identifiers.
    enum Account {
        /// Google AI Studio API key for Gemini 3.5 Transcribe (Primary & Free Tier).
        static let googleApiKey = "google_api_key"
        /// Optional OpenRouter key fallback.
        static let openrouterKey = "openrouter_key"
        /// Optional Groq key for ultra-fast Whisper (~300ms).
        static let groqApiKey = "groq_api_key"
    }

    /// What `set` must do with a user-supplied raw value (internal seam for
    /// offline unit tests): whitespace-only input removes the item, anything
    /// else is trimmed and upserted.
    enum SetAction: Equatable {
        case remove
        case upsert(String)
    }

    static func setAction(for rawValue: String) -> SetAction {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .remove : .upsert(trimmed)
    }

    // MARK: - Keychain primitives (Security framework)

    private static func keychainAccount(for account: String) -> String {
        prefix + account
    }

    private static func makeQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Returns the stored secret, or nil when absent/unavailable.
    private static func read(account: String) -> String? {
        var query = makeQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Update-in-place, falling back to add. Returns the final OSStatus.
    private static func upsert(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(makeQuery(account: account) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var add = makeQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Migration decision core (internal seam for offline unit tests)

    /// Outcome of a legacy→Keychain migration attempt.
    enum MigrationDecision: Equatable {
        /// Keychain provably holds the legacy value; the legacy copy may be retired.
        case migrated
        /// The Keychain could not be proven to hold the value: keep the legacy
        /// copy and let `get` return the associated legacy value (the key is
        /// never lost).
        case preserved(String)
    }

    /// Pure decision core of `migrateLegacy` (no Keychain/UserDefaults I/O):
    /// legacy may be cleared ONLY when the upsert status is success/duplicate
    /// AND the Keychain read-back equals the legacy value.
    static func migrationDecision(status: OSStatus, readBack: String?, raw: String) -> MigrationDecision {
        if isKeychainLockedOrUnavailable(status) { return .preserved(raw) }
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            // nil/empty/different read-back → keep the legacy copy (fail-safe).
            return readBack == raw ? .migrated : .preserved(raw)
        default:
            return .preserved(raw)
        }
    }

    /// Distinguishes a plain keychain miss from locked/unavailable states:
    /// migration must never run (and legacy must never be cleared) while the
    /// Keychain denies access or is unavailable.
    static func isKeychainLockedOrUnavailable(_ status: OSStatus) -> Bool {
        switch status {
        case errSecInteractionNotAllowed, // keychain locked / access denied
             errSecNotAvailable,          // no keychain available
             errSecNoSuchKeychain,        // keychain missing
             errSecInvalidKeychain,       // keychain invalid
             errSecAuthFailed:            // authentication/access failure
            return true
        default:
            return false
        }
    }

    // MARK: - One-time legacy migration (UserDefaults `secret.*` → Keychain)

    /// Moves a legacy value into the Keychain. The UserDefaults entry is
    /// deleted ONLY after a read-back proves the Keychain now holds the exact
    /// same value, so a failed/locked write, a racing duplicate or a mismatched
    /// item never loses the user's key.
    private static func migrateLegacy(_ account: String) -> String? {
        let legacyKey = prefix + account
        guard let raw = UserDefaults.standard.string(forKey: legacyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        let kcAccount = keychainAccount(for: account)
        let status = upsert(raw, account: kcAccount)
        // Read-back only makes sense after a write/add attempt; for other
        // statuses (locked/unavailable/failed) go straight to preservation.
        let readBack: String?
        switch status {
        case errSecSuccess, errSecDuplicateItem:
            readBack = read(account: kcAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            readBack = nil
        }

        switch migrationDecision(status: status, readBack: readBack, raw: raw) {
        case .migrated:
            clearLegacy(account)
            return raw
        case .preserved(let fallback):
            // Keep the legacy value in place; `get` returns it (or nil when
            // there is nothing) instead of losing the key.
            return fallback
        }
    }

    private static func clearLegacy(_ account: String) {
        UserDefaults.standard.removeObject(forKey: prefix + account)
    }
}

extension Notification.Name {
    static let secretStoreDidChange = Notification.Name("SecretStoreDidChangeNotification")
}
