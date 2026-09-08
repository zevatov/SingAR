import XCTest
@testable import SingAR

/// PRE-DMG-FIX offline regression for the session-scoped target ownership
/// gate (`DictationFocusTargetGate`). Pure state via a fake AX probe: no app
/// run, no real AX/CGEvent/Keychain/network/microphone, no defaults writes,
/// no skips.
final class DictationFocusTargetGateTests: XCTestCase {

    // MARK: Fake AX surface

    private final class FakeAXFocusProbe: AXFocusProbing {
        var trusted = true
        var secureInput = false
        var facts: FocusedElementFacts?
        func isProcessTrusted() -> Bool { trusted }
        func isSecureEventInput() -> Bool { secureInput }
        func readFocusedFacts() -> FocusedElementFacts? { facts }
    }

    // MARK: Fixtures

    private func identity(
        role: String? = "AXTextArea",
        title: String? = "Document",
        description: String? = "editor",
        windowTitle: String? = "Main Window",
        position: CGPoint? = CGPoint(x: 10, y: 20),
        size: CGSize? = CGSize(width: 400, height: 200)
    ) -> FocusedElementIdentity {
        FocusedElementIdentity(
            role: role,
            title: title,
            descriptionValue: description,
            windowTitle: windowTitle,
            position: position,
            size: size
        )
    }

    private func facts(
        pid: pid_t = 4242,
        identity id: FocusedElementIdentity? = nil,
        settable: Bool = true,
        value: String? = "",
        selection: NSRange? = nil
    ) -> FocusedElementFacts {
        FocusedElementFacts(
            pid: pid,
            identity: id ?? identity(),
            isValueSettable: settable,
            value: value,
            selectedRange: selection
        )
    }

    // MARK: Capture fail-closed

    func testCaptureFailsClosedWhenAXUntrusted() {
        let probe = FakeAXFocusProbe()
        probe.trusted = false
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertFalse(gate.captureSessionTarget(generation: 1), "untrusted AX ⇒ no target, no fallback")
        XCTAssertEqual(gate.canMutate(generation: 1), .generationStale, "no capture ⇒ no mutation")
    }

    func testCaptureFailsClosedOnSecureEventInput() {
        let probe = FakeAXFocusProbe()
        probe.secureInput = true
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertFalse(gate.captureSessionTarget(generation: 1), "secure event input ⇒ never write")
    }

    func testCaptureFailsClosedWhenNoFocusedElementOrNotEditable() {
        let gate1 = DictationFocusTargetGate(probe: FakeAXFocusProbe()) // facts nil (AX error/none)
        XCTAssertFalse(gate1.captureSessionTarget(generation: 1))
        XCTAssertEqual(gate1.canMutate(generation: 1), .generationStale)

        let probe2 = FakeAXFocusProbe()
        probe2.facts = facts(settable: false)
        let gate2 = DictationFocusTargetGate(probe: probe2)
        XCTAssertFalse(gate2.captureSessionTarget(generation: 1), "non-settable value ⇒ not an editable target")
    }

    func testCaptureFailsClosedWithoutSemanticIdentityRole() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(identity: identity(role: nil))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertFalse(gate.captureSessionTarget(generation: 1), "no role ⇒ identity unverifiable ⇒ deny")
    }

    func testCaptureAllowsVerifiedEditableTarget() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "", selection: NSRange(location: 0, length: 0))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 7))
        XCTAssertNil(gate.canMutate(generation: 7))
        XCTAssertEqual(gate.capturedPID, 4242)
        XCTAssertEqual(gate.capturedGeneration, 7)
    }

    // MARK: Identity / PID checks before mutation

    func testSamePIDDifferentElementDenied() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        // Same PID, different semantic identity: a field switch inside the
        // same app must be denied for both live and destructive mutation.
        probe.facts = facts(identity: identity(title: "Other Field"))
        XCTAssertEqual(gate.canMutate(generation: 1), .foreignTarget)
        XCTAssertEqual(ownedDenial(gate, "abc"), .foreignTarget)
    }

    func testEachIdentityComponentIsCompared() {
        let variants: [FocusedElementIdentity] = [
            identity(role: "AXTextField"),
            identity(title: "Renamed"),
            identity(description: "other"),
            identity(windowTitle: "Other Window"),
            identity(position: CGPoint(x: 99, y: 99)),
            identity(size: CGSize(width: 1, height: 1)),
        ]
        for (index, variant) in variants.enumerated() {
            let probe = FakeAXFocusProbe()
            probe.facts = facts()
            let gate = DictationFocusTargetGate(probe: probe)
            XCTAssertTrue(gate.captureSessionTarget(generation: 1), "fixture \(index)")
            probe.facts = facts(identity: variant)
            XCTAssertEqual(
                gate.canMutate(generation: 1),
                .foreignTarget,
                "identity component \(index) must participate (no single hash)"
            )
        }
    }

    func testDifferentPIDDenied() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))
        probe.facts = facts(pid: 9999) // same identity shape, another process
        XCTAssertEqual(gate.canMutate(generation: 1), .foreignTarget)
    }

    func testMutationFailsClosedOnAXDegradation() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        probe.facts = nil
        XCTAssertEqual(gate.canMutate(generation: 1), .noFocusedElement, "AX read error/nil ⇒ deny")

        probe.facts = facts()
        probe.trusted = false
        XCTAssertEqual(gate.canMutate(generation: 1), .axUnavailable)

        probe.trusted = true
        probe.secureInput = true
        XCTAssertEqual(gate.canMutate(generation: 1), .secureInput)
    }

    func testStaleGenerationDeniedAndNewCaptureDropsOldTarget() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts()
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        XCTAssertEqual(gate.canMutate(generation: 2), .generationStale, "foreign generation cannot mutate")

        // A NEW session's capture resets the target: the stale generation can
        // never reuse it, even though the element is unchanged.
        XCTAssertTrue(gate.captureSessionTarget(generation: 2))
        XCTAssertEqual(gate.canMutate(generation: 1), .generationStale)
        XCTAssertNil(gate.canMutate(generation: 2))

        // invalidate drops only the matching generation's capture.
        gate.invalidate(generation: 1)
        XCTAssertNotNil(gate.capturedPID, "foreign generation must not invalidate a newer capture")
        gate.invalidate(generation: 2)
        XCTAssertNil(gate.capturedPID)
        XCTAssertEqual(gate.canMutate(generation: 2), .generationStale)
    }

    // MARK: Destructive ownership proofs

    func testDestructiveReplaceAllowedForStableOwnership() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "Hello dictation world", selection: NSRange(location: 15, length: 0))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        let result = gate.verifiedOwnedRange(generation: 1, ownedText: "dictation")
        guard case .success(let range) = result else {
            return XCTFail("stable ownership must be allowed, got \(result)")
        }
        XCTAssertEqual(range, NSRange(location: 6, length: 9))
    }

    func testDestructiveReplaceDeniedWhenSelectionMovedOrNonEmpty() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "Hello dictation", selection: NSRange(location: 15, length: 0))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        probe.facts = facts(value: "Hello dictation", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(ownedDenial(gate, "dictation"), .snapshotMismatch, "caret moved off the owned end ⇒ deny")

        probe.facts = facts(value: "Hello dictation", selection: NSRange(location: 15, length: 3))
        XCTAssertEqual(ownedDenial(gate, "dictation"), .snapshotMismatch, "user selection ⇒ deny")
    }

    func testDestructiveReplaceDeniedWhenSelectionUnavailable() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "Hello dictation", selection: nil)
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))
        XCTAssertEqual(ownedDenial(gate, "dictation"), .selectionUnavailable, "no AX selection ⇒ no destructive edit")
    }

    func testDestructiveReplaceDeniedWhenOwnedTextNoLongerMatches() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "Hello dictation", selection: NSRange(location: 15, length: 0))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        probe.facts = facts(value: "Hello dictcatoin", selection: NSRange(location: 16, length: 0))
        XCTAssertEqual(ownedDenial(gate, "dictation"), .snapshotMismatch, "user typed into the window ⇒ deny")

        probe.facts = facts(value: nil, selection: NSRange(location: 15, length: 0))
        XCTAssertEqual(ownedDenial(gate, "dictation"), .snapshotMismatch, "unreadable value ⇒ deny")
    }

    /// PRE-DMG-D1-FIX regression: success-history is written ONLY after a
    /// verifiedOwnedRange .success; a .failure must leave NO new history
    /// entry. Mirrors the finalize branches of DictationController using the
    /// existing fake probe seam and an isolated history (temp file + suite):
    /// no app run, no real AX/Keychain/network.
    func testNoSuccessHistoryWhenVerifiedOwnedRangeFails() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-d1-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("history.json")
        let suiteName = "test.singar.d1." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        let history = DictationHistory(fileURL: fileURL, defaults: defaults)

        func recordSuccessHistory() {
            history.append(DictationHistoryEntry(
                timestamp: Date(),
                provider: "test",
                model: "test-model",
                latencyMs: 100,
                text: "final"
            ))
        }

        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "Hello dictation world", selection: NSRange(location: 15, length: 0))
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        // Success branch: insert/replace happens, THEN history is recorded.
        if case .success = gate.verifiedOwnedRange(generation: 1, ownedText: "dictation") {
            recordSuccessHistory()
        } else {
            XCTFail("stable ownership must succeed")
        }
        XCTAssertEqual(history.items.count, 1, "success ⇒ exactly one entry")

        // Failure branch (user typed into the owned window): NO destructive
        // replace, NO history append — the success count must stay at 1.
        probe.facts = facts(value: "Hello dictcatoin", selection: NSRange(location: 16, length: 0))
        if case .failure(let denial) = gate.verifiedOwnedRange(generation: 1, ownedText: "dictation") {
            XCTAssertEqual(denial, .snapshotMismatch)
        } else {
            XCTFail("mismatched owned window must fail")
        }
        XCTAssertEqual(history.items.count, 1, "verifiedOwnedRange .failure ⇒ no success history")
    }

    func testAppendOnlyTailVerification() {
        let probe = FakeAXFocusProbe()
        probe.facts = facts(value: "tail owns", selection: nil)
        let gate = DictationFocusTargetGate(probe: probe)
        XCTAssertTrue(gate.captureSessionTarget(generation: 1))

        XCTAssertNil(gate.verifiedAppendTail(generation: 1, ownedText: "owns"), "value still ends with owned text")
        probe.facts = facts(value: "tail ownz", selection: nil)
        XCTAssertEqual(gate.verifiedAppendTail(generation: 1, ownedText: "owns"), .snapshotMismatch)
        XCTAssertEqual(gate.verifiedAppendTail(generation: 2, ownedText: "owns"), .generationStale)
    }

    // MARK: Helpers

    private func ownedDenial(_ gate: DictationFocusTargetGate, _ owned: String) -> FocusTargetDenial? {
        if case .failure(let denial) = gate.verifiedOwnedRange(generation: 1, ownedText: owned) {
            return denial
        }
        return nil
    }
}
