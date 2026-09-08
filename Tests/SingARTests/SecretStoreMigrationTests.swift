import XCTest
@testable import SingAR

/// Offline regression tests for the `SecretStore` legacy-migration fail-safe
/// (UserDefaults `secret.*` → Keychain). Pure decision core only: no real
/// Keychain, no UserDefaults, no network, no app run. Locked/unavailable
/// keychain states are simulated with real Security-framework OSStatus values
/// through the internal testable seams (`migrationDecision`,
/// `isKeychainLockedOrUnavailable`, `setAction`).
final class SecretStoreMigrationTests: XCTestCase {

    private let raw = "legacy-api-key-123"

    // MARK: - success/duplicate + matching read-back → legacy cleared

    func testSuccessWithMatchingReadBackClearsLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecSuccess, readBack: raw, raw: raw)
        XCTAssertEqual(decision, .migrated)
    }

    func testDuplicateWithMatchingReadBackClearsLegacy() {
        // errSecDuplicateItem: an item appeared between SecItemUpdate and
        // SecItemAdd (race) and its content equals the legacy value.
        let decision = SecretStore.migrationDecision(status: errSecDuplicateItem, readBack: raw, raw: raw)
        XCTAssertEqual(decision, .migrated)
    }

    // MARK: - mismatch/nil read-back → legacy preserved (no key loss)

    func testSuccessWithNilReadBackPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecSuccess, readBack: nil, raw: raw)
        XCTAssertEqual(decision, .preserved(raw), "nil read-back must keep the legacy copy")
    }

    func testDuplicateWithMismatchedReadBackPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecDuplicateItem, readBack: "a-different-key", raw: raw)
        XCTAssertEqual(decision, .preserved(raw), "mismatched keychain content must not retire the legacy copy")
    }

    func testEmptyReadBackPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecSuccess, readBack: "", raw: raw)
        XCTAssertEqual(decision, .preserved(raw))
    }

    // MARK: - locked/unavailable keychain → never migrate

    func testLockedKeychainPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecInteractionNotAllowed, readBack: nil, raw: raw)
        XCTAssertEqual(decision, .preserved(raw), "locked keychain must not migrate nor clear legacy")
    }

    func testUnavailableKeychainPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecNotAvailable, readBack: nil, raw: raw)
        XCTAssertEqual(decision, .preserved(raw))
    }

    func testAccessErrorStatusesAreClassifiedAsLockedOrUnavailable() {
        XCTAssertTrue(SecretStore.isKeychainLockedOrUnavailable(errSecInteractionNotAllowed))
        XCTAssertTrue(SecretStore.isKeychainLockedOrUnavailable(errSecNotAvailable))
        XCTAssertTrue(SecretStore.isKeychainLockedOrUnavailable(errSecNoSuchKeychain))
        XCTAssertTrue(SecretStore.isKeychainLockedOrUnavailable(errSecInvalidKeychain))
        XCTAssertTrue(SecretStore.isKeychainLockedOrUnavailable(errSecAuthFailed))
        // A plain keychain miss is NOT locked: migration may proceed.
        XCTAssertFalse(SecretStore.isKeychainLockedOrUnavailable(errSecItemNotFound))
    }

    // MARK: - other write errors → legacy preserved

    func testWriteErrorPreservesLegacy() {
        let decision = SecretStore.migrationDecision(status: errSecIO, readBack: nil, raw: raw)
        XCTAssertEqual(decision, .preserved(raw))
    }

    func testAnyFailureModeKeepsLegacyValueReturnable() {
        // Whatever the failure mode, `get` must still be able to return the
        // legacy value so the key is never lost.
        let statuses: [OSStatus] = [
            errSecSuccess, errSecDuplicateItem, errSecInteractionNotAllowed,
            errSecNotAvailable, errSecNoSuchKeychain, errSecIO,
        ]
        for status in statuses {
            let decision = SecretStore.migrationDecision(status: status, readBack: nil, raw: raw)
            XCTAssertEqual(decision, .preserved(raw), "status \(status) must preserve the legacy value")
        }
    }

    // MARK: - set semantics (trim / empty → remove), no Keychain I/O

    func testSetActionEmptyOrWhitespaceMeansRemove() {
        XCTAssertEqual(SecretStore.setAction(for: ""), .remove)
        XCTAssertEqual(SecretStore.setAction(for: "   \n\t "), .remove)
    }

    func testSetActionTrimsValueBeforeUpsert() {
        XCTAssertEqual(SecretStore.setAction(for: "  api-key  "), .upsert("api-key"))
    }
}
