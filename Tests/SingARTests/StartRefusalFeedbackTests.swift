import XCTest
@testable import SingAR

/// FIX-A offline regression: a fail-closed start refusal must still produce
/// visible user feedback, while a successful capture must never show refusal
/// UI and the fail-closed gate semantics must stay untouched.
///
/// Pure offline logic only (same style as `DictationFocusTargetGateTests`,
/// `AudioCaptureBudgetTests`): fake AX probe + static decision helpers.
/// No app run, no real AX/CGEvent/microphone/network, no defaults writes.
final class StartRefusalFeedbackTests: XCTestCase {

    // MARK: Fake AX surface (mirrors DictationFocusTargetGateTests)

    private final class FakeAXFocusProbe: AXFocusProbing {
        var trusted = true
        var secureInput = false
        var facts: FocusedElementFacts?
        func isProcessTrusted() -> Bool { trusted }
        func isSecureEventInput() -> Bool { secureInput }
        func readFocusedFacts() -> FocusedElementFacts? { facts }
    }

    private func facts(
        pid: pid_t = 4242,
        settable: Bool = true
    ) -> FocusedElementFacts {
        FocusedElementFacts(
            pid: pid,
            identity: FocusedElementIdentity(
                role: "AXTextArea",
                title: "Document",
                descriptionValue: "editor",
                windowTitle: "Main Window",
                position: CGPoint(x: 10, y: 20),
                size: CGSize(width: 400, height: 200)
            ),
            isValueSettable: settable,
            value: "",
            selectedRange: NSRange(location: 0, length: 0)
        )
    }

    // MARK: Decision helper — refusal ⇒ feedback, success ⇒ none

    func testRefusalProducesFeedback() {
        XCTAssertTrue(
            DictationController.showsRefusalFeedback(captureSucceeded: false),
            "FIX-A: a refused fail-closed capture MUST surface visible feedback"
        )
    }

    func testSuccessfulCaptureNeverShowsRefusalFeedback() {
        XCTAssertFalse(
            DictationController.showsRefusalFeedback(captureSucceeded: true),
            "a verified capture must never show the refusal capsule"
        )
    }

    // MARK: Message & hide-window contract

    func testRefusalMessageIsNonEmptyAndContentFree() {
        let message = DictationController.startRefusalMessage
        XCTAssertFalse(message.isEmpty, "the refusal message must be user-visible")
        // Content-free: no PID/user-text ever leaks into the capsule.
        XCTAssertFalse(message.contains("4242"))
        XCTAssertFalse(message.lowercased().contains("pid"))
    }

    // MARK: FIX-STEP1 — refusal cause discrimination (presentation only)

    func testDeniedAccessibilityRefusalPointsToSettings() {
        // AX explicitly denied ⇒ the capsule must name the Settings path,
        // not the generic "focus the field" hint.
        XCTAssertEqual(
            DictationController.refusalMessage(axStatus: .denied),
            "Нужен доступ: Настройки → Конфиденциальность → Универсальный доступ"
        )
        XCTAssertEqual(
            DictationController.refusalReason(axStatus: .denied),
            .axDenied
        )
    }

    func testGrantedAccessibilityRefusalKeepsGenericMessage() {
        // AX granted but capture still refused (secure input / no focused
        // element / non-settable target) ⇒ the ORIGINAL generic message.
        XCTAssertEqual(
            DictationController.refusalMessage(axStatus: .granted),
            DictationController.startRefusalMessage
        )
        XCTAssertEqual(
            DictationController.refusalReason(axStatus: .granted),
            .focusOrSecureInput
        )
    }

    func testUnknownAccessibilityFailsClosedToGenericMessage() {
        // An unreadable AX status never claims a Settings problem it cannot
        // prove: `unknown` keeps the generic message (fail-closed UI).
        XCTAssertEqual(
            DictationController.refusalMessage(axStatus: .unknown),
            DictationController.startRefusalMessage
        )
        XCTAssertEqual(
            DictationController.refusalReason(axStatus: .unknown),
            .focusOrSecureInput
        )
    }

    func testDeniedAccessibilityMessageIsContentFree() {
        let message = DictationController.axDeniedRefusalMessage
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("4242"))
        XCTAssertFalse(message.lowercased().contains("pid"))
        XCTAssertTrue(message.contains("Универсальный доступ"))
    }

    func testRefusalHideWindowMatchesExistingFailurePaths() {
        // All existing failure paths auto-hide the failed capsule after 1.2s
        // (finalize rejection, owned-range denial, empty commit). The refusal
        // capsule must reuse the SAME mechanism/duration.
        XCTAssertEqual(
            DictationController.refusalFeedbackHideDelay, 1.2,
            accuracy: 0.0001
        )
    }

    // MARK: Fail-closed semantics unchanged by FIX-A

    func testCaptureRefusalLeavesNoMutableTarget() {
        let probe = FakeAXFocusProbe()
        probe.trusted = false // AX gate refuses (pre-existing fail-closed path)
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        let captureSucceeded = gate.captureSessionTarget(generation: 1)
        XCTAssertFalse(captureSucceeded, "untrusted AX must still deny (FIX-A must not weaken this)")
        XCTAssertTrue(
            DictationController.showsRefusalFeedback(captureSucceeded: captureSucceeded),
            "the denied capture is exactly the case that must show feedback"
        )
        XCTAssertEqual(
            gate.canMutate(generation: 1), .generationStale,
            "a refused start must leave NO capturable target — no fallback write path"
        )
    }

    func testSecureInputRefusalStillDeniesAndShowsFeedback() {
        let probe = FakeAXFocusProbe()
        probe.secureInput = true
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        let captureSucceeded = gate.captureSessionTarget(generation: 1)
        XCTAssertFalse(captureSucceeded, "secure event input must still deny")
        XCTAssertTrue(DictationController.showsRefusalFeedback(captureSucceeded: captureSucceeded))
        XCTAssertEqual(gate.canMutate(generation: 1), .generationStale)
    }

    func testSuccessfulCaptureStaysAuthoritativeForWrites() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        let captureSucceeded = gate.captureSessionTarget(generation: 7)
        XCTAssertTrue(captureSucceeded, "a verified editable target still captures")
        XCTAssertNil(gate.canMutate(generation: 7), "captured target remains the only write authority")
        XCTAssertFalse(
            DictationController.showsRefusalFeedback(captureSucceeded: captureSucceeded),
            "successful sessions must not flash the refusal capsule"
        )
    }
}
