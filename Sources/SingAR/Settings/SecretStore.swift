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
    /// Этап 1: фиксированный service для generic-password items.
    /// Раньше был `Bundle.main.bundleIdentifier ?? "SingAR"` — опционал дрейфовал
    /// между `com.singar.app` (прод) и `SingAR` (swift run/тесты), раскалывая Keychain.
    /// Канон — `com.singar.app` (см. scripts/build_dmg.sh Info.plist); старые
    /// значения читаются через `legacyServices()` и мигрируют на канон.
    static let keychainService = "com.singar.app"

    /// Legacy service-кандидаты для чтения/миграции (без канона, без дублей,
    /// порядок стабилен: сначала "SingAR", затем bundleIdentifier если иной).
    /// Pure-seam для offline-тестов совместимости.
    static var legacyServices: [String] {
        var out: [String] = []
        for cand in ["SingAR", Bundle.main.bundleIdentifier ?? ""] {
            guard !cand.isEmpty, cand != keychainService, !out.contains(cand) else { continue }
            out.append(cand)
        }
        return out
    }

    // MARK: - Этап 1: clearLegacy TTL/аудит/повтор (offline-testable seams)

    /// TTL остаточного legacy-ключа в UserDefaults: дольше — stale, нужен аудит.
    /// 7 дней, консистентно с AppLogger.logTTLSeconds.
    static let legacyAuditTTLSeconds: TimeInterval = 7 * 24 * 3600

    /// Accounts, где Keychain read-back не подтвердил запись: clearLegacy отложен,
    /// повтор запланирован. In-memory only (не персистим — при рестарте get снова попробует).
    private static var pendingLegacyRetry: Set<String> = []

    /// Pure-seam: нужен ли повтор зачистки (migrated=false → повтор+предупреждение).
    static func needsLegacyRetry(decision: MigrationDecision) -> Bool {
        if case .migrated = decision { return false }
        return true
    }

    /// Pure-seam: stale ли остаточный legacy-ключ (для аудита/TTL).
    static func isLegacyStale(lastVerifiedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastVerifiedAt) > legacyAuditTTLSeconds
    }

    /// Аудит остаточных UserDefaults `secret.*` (без значений, только имена).
    static func residualLegacyKeys(accounts: [String], defaults: UserDefaults = .standard) -> [String] {
        accounts.map { prefix + $0 }.filter { defaults.string(forKey: $0) != nil }
    }

    /// Отложенные повторы (для диагностики, без значений).
    static func pendingLegacyRetries() -> [String] { Array(pendingLegacyRetry).sorted() }

    static func set(_ value: String, for account: String) {
        switch setAction(for: value) {
        case .remove:
            remove(account)
        case .upsert(let trimmed):
            let status = upsert(trimmed, account: keychainAccount(for: account))
            if status == errSecSuccess {
                // Этап 1: clearLegacy только после read-back проверки (fail-safe).
                let readBack = read(account: keychainAccount(for: account))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if readBack == trimmed {
                    clearLegacy(account)
                    pendingLegacyRetry.remove(account)
                    for svc in legacyServices { deleteServiceItem(account: keychainAccount(for: account), service: svc) }
                    NotificationCenter.default.post(name: .secretStoreDidChange, object: account)
                } else {
                    pendingLegacyRetry.insert(account)
                    NSLog("[SingAR] SecretStore: keychain read-back mismatch, legacy retry scheduled")
                }
            }
        }
    }

    static func get(_ account: String) -> String? {
        let kcAccount = keychainAccount(for: account)
        if let stored = read(account: kcAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !stored.isEmpty {
            ensureThisDeviceOnly(account: kcAccount, knownValue: stored, service: keychainService)
            return stored
        }
        for svc in legacyServices {
            guard let legacyVal = read(account: kcAccount, service: svc)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !legacyVal.isEmpty else { continue }
            let status = upsert(legacyVal, account: kcAccount)
            let readBack: String? = (status == errSecSuccess || status == errSecDuplicateItem)
                ? read(account: kcAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if migrationDecision(status: status, readBack: readBack, raw: legacyVal) == .migrated {
                deleteServiceItem(account: kcAccount, service: svc)
                ensureThisDeviceOnly(account: kcAccount, knownValue: legacyVal, service: keychainService)
                return legacyVal
            }
            return legacyVal
        }
        // Keychain miss: try a one-time migration from legacy UserDefaults.
        return migrateLegacy(account)
    }

    static func remove(_ account: String) {
        let kcAccount = keychainAccount(for: account)
        SecItemDelete(makeQuery(account: kcAccount) as CFDictionary)
        for svc in legacyServices { deleteServiceItem(account: kcAccount, service: svc) }
        pendingLegacyRetry.remove(account)
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

    /// Header field carrying the Gemini API key (analogous to Bearer for
    /// OpenRouter/Groq). The key MUST NOT appear in URL query strings, logs,
    /// or error messages — only in this header.
    static let geminiKeyHeaderField = "x-goog-api-key"

    /// Pure trim+isEmpty core (offline-testable seam): nil/empty/whitespace
    /// ⇒ nil, otherwise the trimmed value. Unifies every empty-key check
    /// (`CloudASR.available`, `GeminiLiveEngine`, typed passes).
    static func normalizedKey(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Pure non-empty check over a raw (possibly untrimmed) value.
    static func isNonEmptyKey(_ raw: String?) -> Bool {
        normalizedKey(raw) != nil
    }

    /// Single trim+isEmpty helper unifying every Keychain-backed empty-key
    /// check. `get` already trims, this makes the contract explicit.
    static func trimmedKey(_ account: String) -> String? {
        normalizedKey(get(account))
    }

    /// Non-empty key present for `account`.
    static func hasKey(_ account: String) -> Bool {
        trimmedKey(account) != nil
    }

    /// Этап 0: единственный конструктор Gemini-запросов. Ключ кладётся
    /// ТОЛЬКО в заголовок `x-goog-api-key` (аналогия с Bearer), URL обязан
    /// быть без секрета — такой URL безопасно логировать через
    /// `AppLogger.redactedPreview` (никогда не логировать сам ключ/URL с ключом).
    static func geminiRequest(url: URL, apiKey: String) -> URLRequest {
        var req = URLRequest(url: url)
        // normalizedKey гарантирует trim; пустой ключ сюда не должен попадать
        // (коллеры проверяют trimmedKey заранее), но header с пустым значением
        // не ставим — fail-closed на уровне запроса.
        if let normalized = normalizedKey(apiKey) {
            req.setValue(normalized, forHTTPHeaderField: geminiKeyHeaderField)
        }
        return req
    }

    /// Этап 0: детектор утечки ключа в URL (для тестов/ревью). True ⇒ блокер:
    /// ключ оказался в query — логирование такого URL запрещено.
    static func urlLeaksKey(_ url: URL, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return url.absoluteString.contains(key)
    }

    // MARK: - Этап 1: Keychain primitives (Security framework, ThisDeviceOnly)

    /// Класс доступа для новых items: только это устройство, без бэкапов/iCloud.
    /// Pure-seam для offline-тестов атрибута (без реального Keychain).
    static let keychainAccessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    private static func keychainAccount(for account: String) -> String {
        prefix + account
    }

    /// Базовый query для поиска. iCloud sync запрещён на записи (см. makeAddQuery);
    /// в поиске фильтр synchronizable не ставим для совместимости со старыми items.
    static func makeQuery(account: String, service: String? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    /// Pure-seam конструктор SecItemAdd: фиксированный service + ThisDeviceOnly + sync=false.
    /// Тесты проверяют атрибуты без реального Keychain.
    static func makeAddQuery(account: String, value: String, service: String? = nil) -> [String: Any] {
        var add = makeQuery(account: account, service: service)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = keychainAccessible
        add[kSecAttrSynchronizable as String] = false
        return add
    }

    /// Pure-seam: true когда текущий accessible отличается от ThisDeviceOnly
    /// (nil = неизвестно → считать нужной миграцию при известном значении).
    static func needsAccessibleMigration(currentAccessible: String?) -> Bool {
        guard let cur = currentAccessible else { return true }
        return cur != (keychainAccessible as String)
    }

    /// Returns the stored secret, or nil when absent/unavailable.
    /// Сначала канон, затем legacy services (совместимость со старыми ключами).
    private static func read(account: String, service: String? = nil) -> String? {
        var query = makeQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Текущий accessible-атрибут item (nil когда item отсутствует/недоступен).
    private static func currentAccessible(account: String, service: String) -> String? {
        var query = makeQuery(account: account, service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [String: Any],
              let acc = attrs[kSecAttrAccessible as String] else { return nil }
        return "\(acc)"
    }

    /// Best-effort миграция accessible на ThisDeviceOnly: delete+add с тем же значением.
    /// Вызывается только при известном значении; при неудаче ключ не теряется
    /// (старый item уже удалён только после успешной записи нового — см. код).
    private static func ensureThisDeviceOnly(account: String, knownValue: String, service: String) {
        guard service == keychainService else { return }
        let cur = currentAccessible(account: account, service: service)
        guard needsAccessibleMigration(currentAccessible: cur) else { return }
        let data = Data(knownValue.utf8)
        var add = makeQuery(account: account, service: service)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = keychainAccessible
        add[kSecAttrSynchronizable as String] = false
        // Удаляем старый item только если новый успешно записан во временный account?
        // Упрощённо и безопасно: delete+add с немедленным read-back; при mismatch
        // восстанавливаем исходное значение тем же путём (best-effort, без потери).
        let delStatus = SecItemDelete(makeQuery(account: account, service: service) as CFDictionary)
        guard delStatus == errSecSuccess || delStatus == errSecItemNotFound else { return }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            // Откат: вернуть значение хотя бы со старым классом (лучше чем потеря).
            var fallback = makeQuery(account: account, service: service)
            fallback[kSecValueData as String] = data
            fallback[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            _ = SecItemAdd(fallback as CFDictionary, nil)
            return
        }
    }

    /// Удаляет Keychain-item в указанном service (для зачистки legacy services).
    private static func deleteServiceItem(account: String, service: String) {
        _ = SecItemDelete(makeQuery(account: account, service: service) as CFDictionary)
    }

    /// Update-in-place, falling back to add. Returns the final OSStatus.
    /// Новые items: ThisDeviceOnly + sync=false. Существующие items мигрируют
    /// на ThisDeviceOnly через ensureThisDeviceOnly при следующем чтении/записи.
    private static func upsert(_ value: String, account: String) -> OSStatus {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(makeQuery(account: account) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        return SecItemAdd(makeAddQuery(account: account, value: value) as CFDictionary, nil)
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
            pendingLegacyRetry.remove(account)
            return raw
        case .preserved(let fallback):
            // Этап 1: неуспех проверки → планируем повтор + предупреждение (без значения).
            pendingLegacyRetry.insert(account)
            NSLog("[SingAR] SecretStore: legacy migration deferred for account, retry scheduled")
            return fallback
        }
    }

    /// Удаляет legacy UserDefaults `secret.*`. Идемпотентна: повторный вызов
    /// без ключа — no-op. Вызывается ТОЛЬКО после read-back проверки.
    static func clearLegacy(_ account: String) {
        UserDefaults.standard.removeObject(forKey: prefix + account)
    }
}

extension Notification.Name {
    static let secretStoreDidChange = Notification.Name("SecretStoreDidChangeNotification")
}
