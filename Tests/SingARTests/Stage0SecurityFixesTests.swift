import XCTest
@testable import SingAR

/// Этап 0 (GitHub-дистрибуция, ad-hoc подпись): блокеры аудита.
/// Offline, без сети/Keychain-записей/AX: только pure-seams.
/// 1. Ключ Gemini — только в заголовке x-goog-api-key, никогда в query URL;
///    запрет логирования URL с ключом; единый trim+isEmpty хелпер.
/// 2. Fail-closed гейт редактируемости: дефолт — запрет, только settable +
///    whitelist ролей текстовых полей.
/// 3. Плейсхолдер внешнего линка заменён реальным репозиторием (проверяется
///    ревью/поиском: в коде не должно остаться `your_github_repo` и `?key=`).
final class Stage0SecurityFixesTests: XCTestCase {

    // MARK: 1. Единый trim+isEmpty хелпер

    func testNormalizedKeyTrimsAndRejectsEmpty() {
        XCTAssertNil(SecretStore.normalizedKey(nil))
        XCTAssertNil(SecretStore.normalizedKey(""))
        XCTAssertNil(SecretStore.normalizedKey("   \n\t "))
        XCTAssertEqual(SecretStore.normalizedKey("  api-key  "), "api-key")
        XCTAssertFalse(SecretStore.isNonEmptyKey("   "))
        XCTAssertTrue(SecretStore.isNonEmptyKey("  k  "))
    }

    func testGeminiHeaderFieldName() {
        XCTAssertEqual(SecretStore.geminiKeyHeaderField, "x-goog-api-key")
    }

    // MARK: 1. Ключ только в заголовке, URL без секрета

    func testGeminiRequestPutsKeyInHeaderOnly() {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        let req = SecretStore.geminiRequest(url: url, apiKey: "  test-key-123  ")
        XCTAssertEqual(req.value(forHTTPHeaderField: SecretStore.geminiKeyHeaderField), "test-key-123")
        XCTAssertFalse(req.url!.absoluteString.contains("test-key-123"))
        XCTAssertFalse(SecretStore.urlLeaksKey(req.url!, key: "test-key-123"))
    }

    func testGeminiRequestNeverPutsKeyInURL() {
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent")!
        let req = SecretStore.geminiRequest(url: url, apiKey: "secret")
        XCTAssertFalse(req.url!.absoluteString.contains("secret"))
        XCTAssertEqual(req.value(forHTTPHeaderField: SecretStore.geminiKeyHeaderField), "secret")
    }

    func testUrlLeaksKeyDetector() {
        let clean = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        XCTAssertFalse(SecretStore.urlLeaksKey(clean, key: "abc123"))
        let leaked = URL(string: "https://example.com/v1beta/models?key=abc123")!
        XCTAssertTrue(SecretStore.urlLeaksKey(leaked, key: "abc123"))
        XCTAssertFalse(SecretStore.urlLeaksKey(leaked, key: ""))
    }

    // MARK: 2. Fail-closed whitelist ролей

    func testEditableRolesWhitelist() {
        XCTAssertTrue(DictationFocusTargetGate.isEditableRole("AXTextField"))
        XCTAssertTrue(DictationFocusTargetGate.isEditableRole("AXTextArea"))
        XCTAssertTrue(DictationFocusTargetGate.isEditableRole("AXComboBox"))
        XCTAssertTrue(DictationFocusTargetGate.isEditableRole("AXSearchField"))
        XCTAssertTrue(DictationFocusTargetGate.isEditableRole("AXWebArea"))
        // Дефолт — запрет:
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole(nil))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole("AXStaticText"))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole("AXButton"))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole("AXWindow"))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole("AXApplication"))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole("AXFocusedUIElement"))
        XCTAssertFalse(DictationFocusTargetGate.isEditableRole(""))
    }

    // MARK: 2. Гейт через fake probe

    private final class FakeProbe: AXFocusProbing {
        var facts: FocusedElementFacts?
        func isProcessTrusted() -> Bool { true }
        func isSecureEventInput() -> Bool { false }
        func readFocusedFacts() -> FocusedElementFacts? { facts }
    }

    private func facts(role: String?, settable: Bool) -> FocusedElementFacts {
        FocusedElementFacts(
            pid: 111,
            identity: FocusedElementIdentity(
                role: role, title: "Doc", descriptionValue: "ed",
                windowTitle: "W", position: nil, size: nil
            ),
            isValueSettable: settable,
            value: "",
            selectedRange: nil
        )
    }

    func testCaptureDeniesNonWhitelistRoleEvenWhenSettable() {
        for role in ["AXStaticText", "AXButton", "AXWindow", "AXApplication", "AXFocusedUIElement", nil] {
            let probe = FakeProbe()
            probe.facts = facts(role: role, settable: true)
            let gate = DictationFocusTargetGate(probe: probe)
            XCTAssertFalse(
                gate.captureSessionTarget(generation: 1),
                "роль \(String(describing: role)) с settable=true обязана отклоняться (fail-closed)"
            )
        }
    }

    func testCaptureDeniesNonSettableEvenWithWhitelistRole() {
        let probe = FakeProbe()
        probe.facts = facts(role: "AXTextField", settable: false)
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertFalse(gate.captureSessionTarget(generation: 1))
    }

    func testCaptureAllowsWhitelistRoleWithSettable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"] {
            let probe = FakeProbe()
            probe.facts = facts(role: role, settable: true)
            let gate = DictationFocusTargetGate(probe: probe)
            XCTAssertTrue(gate.captureSessionTarget(generation: 1), "роль \(role) обязана разрешаться")
        }
    }

    func testCanMutateDeniesRoleDriftToNonWhitelist() {
        let probe = FakeProbe()
        probe.facts = facts(role: "AXTextArea", settable: true)
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))
        // Тот же PID/identity-форма, но роль ушла в AXButton (напр. фокус на кнопке):
        // fail-closed ⇒ deny до сравнения pid.
        probe.facts = FocusedElementFacts(
            pid: 111,
            identity: FocusedElementIdentity(
                role: "AXButton", title: "Doc", descriptionValue: "ed",
                windowTitle: "W", position: nil, size: nil
            ),
            isValueSettable: true,
            value: "",
            selectedRange: nil
        )
        XCTAssertEqual(gate.canMutate(generation: 1), .foreignTarget)
    }
}
