import XCTest
import Foundation
import Security
@testable import SingAR

/// Этап 1 (доверенные секреты и артефакты): offline-тесты без сети/Keychain-записей.
/// 1. SHA256 модели — pure-seams `verifySHA256`/`verifySHA256Hex`/`sha256HexOfFile`.
/// 2. Keychain ThisDeviceOnly + фиксированный service — pure-seams `makeAddQuery`/`makeQuery`.
/// 3. clearLegacy — `migrationDecision` + `needsLegacyRetry`/`isLegacyStale`/`residualLegacyKeys` + идемпотентность.
/// 4. Санитизация логов — `AppLogger.sanitize`/`sanitizedError`/`isSafeForLog` + права 0600.
final class Stage1SecurityTests: XCTestCase {

    // MARK: 1. SHA256 модели (offline, без сети)

    func testVerifySHA256Match() {
        // SHA256("abc") — эталонный вектор.
        let data = Data("abc".utf8)
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertTrue(ModelDownloadManager.verifySHA256(data: data, expected: expected))
    }

    func testVerifySHA256Mismatch() {
        let data = Data("abc".utf8)
        XCTAssertFalse(ModelDownloadManager.verifySHA256(data: data, expected: String(repeating: "0", count: 64)))
    }

    func testVerifySHA256HexCaseInsensitiveAndTrimmed() {
        XCTAssertTrue(ModelDownloadManager.verifySHA256Hex("  ABCDEF\n", expected: "abcdef"))
        XCTAssertFalse(ModelDownloadManager.verifySHA256Hex("abcdef", expected: "abcdee"))
    }

    func testSha256HexOfFileMatchesInMemory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("singar-stage1-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data("stage1-fixture-hello".utf8)
        try payload.write(to: tmp, options: .atomic)
        let fileHex = try ModelDownloadManager.sha256HexOfFile(at: tmp)
        XCTAssertTrue(ModelDownloadManager.verifySHA256(data: payload, expected: fileHex))
        XCTAssertEqual(fileHex.count, 64)
    }

    func testIsDownloadedFileValidEnforcesExpectedSHA256() throws {
        // G1-1: официальный SHA256 апстрима зафиксирован → fail-closed проверка активна.
        XCTAssertEqual(ModelDownloadManager.expectedSHA256, "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("singar-stage1-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("anything".utf8).write(to: tmp, options: .atomic)
        XCTAssertFalse(ModelDownloadManager.isDownloadedFileValid(at: tmp), "чужой хэш обязан отклоняться (fail-closed)")
    }

    // MARK: 2. Keychain ThisDeviceOnly + фиксированный service

    func testKeychainServiceIsFixed() {
        XCTAssertEqual(SecretStore.keychainService, "com.singar.app")
    }

    func testLegacyServicesExcludesCanonWithoutDupes() {
        let legacy = SecretStore.legacyServices
        XCTAssertFalse(legacy.contains(SecretStore.keychainService))
        XCTAssertEqual(legacy.count, Set(legacy).count)
    }

    func testMakeAddQueryUsesThisDeviceOnlyAndDisablesSync() {
        let q = SecretStore.makeAddQuery(account: "secret.google_api_key", value: "v")
        let accessible = q[kSecAttrAccessible as String] as? String
        XCTAssertEqual(accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(accessible, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecAttrService as String] as? String, SecretStore.keychainService)
    }

    func testMakeQueryDefaultServiceIsCanon() {
        let q = SecretStore.makeQuery(account: "secret.google_api_key")
        XCTAssertEqual(q[kSecAttrService as String] as? String, SecretStore.keychainService)
    }

    func testNeedsAccessibleMigration() {
        XCTAssertTrue(SecretStore.needsAccessibleMigration(currentAccessible: nil))
        XCTAssertTrue(SecretStore.needsAccessibleMigration(currentAccessible: kSecAttrAccessibleAfterFirstUnlock as String))
        XCTAssertFalse(SecretStore.needsAccessibleMigration(currentAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    // MARK: 3. clearLegacy: decision + повтор + TTL/аудит + удаление

    func testNeedsLegacyRetry() {
        XCTAssertFalse(SecretStore.needsLegacyRetry(decision: .migrated))
        XCTAssertTrue(SecretStore.needsLegacyRetry(decision: .preserved("k")))
    }

    func testIsLegacyStaleTTL() {
        let now = Date()
        let weekAgo = now.addingTimeInterval(-6 * 24 * 3600)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        XCTAssertFalse(SecretStore.isLegacyStale(lastVerifiedAt: weekAgo, now: now))
        XCTAssertTrue(SecretStore.isLegacyStale(lastVerifiedAt: old, now: now))
        XCTAssertEqual(SecretStore.legacyAuditTTLSeconds, 7 * 24 * 3600, accuracy: 0.1)
    }

    func testResidualLegacyKeysExposesNamesOnly() {
        let suite = UserDefaults(suiteName: "singar-stage1-\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "") }
        suite.set("SECRET-VALUE", forKey: "secret.google_api_key")
        suite.set("x", forKey: "unrelated")
        let found = SecretStore.residualLegacyKeys(accounts: [SecretStore.Account.googleApiKey, "missing"], defaults: suite)
        XCTAssertEqual(found, ["secret.google_api_key"])
        // Значение не возвращается аудитом — только имя.
        XCTAssertFalse(found.joined().contains("SECRET-VALUE"))
        suite.removeObject(forKey: "secret.google_api_key")
    }

    func testClearLegacyIdempotent() {
        let account = "stage1_idem_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        UserDefaults.standard.set("dummy", forKey: "secret.\(account)")
        SecretStore.clearLegacy(account)
        XCTAssertNil(UserDefaults.standard.string(forKey: "secret.\(account)"))
        // Повторный вызов — no-op, без throw.
        SecretStore.clearLegacy(account)
        XCTAssertNil(UserDefaults.standard.string(forKey: "secret.\(account)"))
    }

    // MARK: 4. Санитизация логов + права файла

    func testSanitizeRemovesURLAndKey() {
        let msg = "fetch https://generativelanguage.googleapis.com/v1beta/models?key=SECRET123 failed"
        let safe = AppLogger.sanitize(msg)
        XCTAssertFalse(safe.contains("SECRET123"))
        XCTAssertFalse(safe.contains("https://"))
        XCTAssertTrue(AppLogger.isSafeForLog(safe))
        XCTAssertFalse(AppLogger.isSafeForLog(msg))
    }

    func testSanitizeRemovesWSSAndHeader() {
        let msg = "ws wss://example.com/socket x-goog-api-key: SECRET456"
        let safe = AppLogger.sanitize(msg)
        XCTAssertFalse(safe.contains("SECRET456"))
        XCTAssertFalse(safe.contains("wss://"))
    }

    func testSanitizedErrorHasNoURLOrBody() {
        let err = URLError(.notConnectedToInternet) as Error
        let s = AppLogger.sanitizedError(err)
        XCTAssertTrue(s.contains("NSURLErrorDomain"))
        XCTAssertFalse(s.contains("https://"))
        XCTAssertFalse(s.lowercased().contains("http"))
    }

    func testRedactedPreviewHidesFullText() {
        let text = "секретный текст диктовки"
        let preview = AppLogger.redactedPreview(text)
        XCTAssertFalse(preview.contains(text))
        XCTAssertTrue(preview.contains("len="))
    }

    func testGeminiReceiveErrorSanitized() {
        let err = URLError(.timedOut) as Error
        let s = GeminiLiveEngine.sanitizedReceiveError(err)
        XCTAssertFalse(s.contains("https://"))
        XCTAssertTrue(s.contains("NSURLErrorDomain"))
    }

    func testEnforceOwnerOnlyPermissions() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("singar-logperm-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        // Ослабляем, затем чиним.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
        AppLogger.enforceOwnerOnlyPermissions(at: tmp)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    }
}
