import XCTest
@testable import SingAR

/// Gate 2.6 offline regression for the production cancel-gate state machine
/// (`DictationCancelGate`, used by `DictationController`) and the production
/// finalize insertion decision (`DictationController.insertionDecision`).
/// Pure state only: no app run, no defaults/Keychain/network/microphone/logs.
final class DictationCancelGateTests: XCTestCase {

    // stop→pending→Esc: the 120ms hand-off window must stay cancellable even
    // though finalizeTask is not installed yet.
    func testStopThenEscBeforeFinalizeTaskInstalledCancels() {
        let gate = DictationCancelGate()
        let gen = gate.beginSession()
        XCTAssertTrue(gate.canCancel, "recording must be cancellable")
        gate.markPendingFinalization(gen: gen)
        XCTAssertEqual(gate.phase, .pendingFinalization)
        XCTAssertTrue(gate.canCancel, "pending hand-off window must be cancellable before finalizeTask is installed")
        XCTAssertTrue(gate.cancel(), "Esc must consume the active window")
        XCTAssertFalse(gate.canCancel, "after Esc the idle Esc must be free")
    }

    // idle: a fresh gate and a naturally finished finalize expose no window.
    func testIdleGateIsNotCancellable() {
        let gate = DictationCancelGate()
        XCTAssertFalse(gate.canCancel)
        XCTAssertFalse(gate.cancel(), "Esc on idle must be a no-op")
        let gen = gate.beginSession()
        gate.markPendingFinalization(gen: gen)
        gate.finalizeFinished(gen: gen)
        XCTAssertEqual(gate.phase, .idle)
        XCTAssertFalse(gate.canCancel, "finished finalize returns to idle")
    }

    // A stale finalize finish must not clear a NEWER session's window.
    func testStaleFinalizeFinishDoesNotResetNewGeneration() {
        let gate = DictationCancelGate()
        let gen1 = gate.beginSession()
        gate.markPendingFinalization(gen: gen1)
        let gen2 = gate.beginSession()
        XCTAssertNotEqual(gen1, gen2, "a new start must bump the generation")
        XCTAssertEqual(gate.phase, .recording, "new start drops the stale pending window")
        gate.markPendingFinalization(gen: gen2)
        gate.finalizeFinished(gen: gen1) // stale finish lands late
        XCTAssertTrue(gate.canCancel, "stale finish must not reset the new generation's window")
        gate.finalizeFinished(gen: gen2)
        XCTAssertFalse(gate.canCancel)
    }

    // pending → finalizeTask installed → still cancellable until cancel/success.
    func testFinalizeTaskInstalledStaysCancellableUntilEnd() {
        let gate = DictationCancelGate()
        let gen = gate.beginSession()
        gate.markPendingFinalization(gen: gen)
        gate.finalizeTaskInstalled(gen: gen)
        XCTAssertEqual(gate.phase, .finalizing)
        XCTAssertTrue(gate.canCancel, "in-flight finalize Task must stay cancellable")
        XCTAssertTrue(gate.cancel())
        gate.finalizeTaskInstalled(gen: gen) // late install after Esc
        XCTAssertFalse(gate.canCancel, "late install must not resurrect a closed window")
    }

    // markPending is rejected for a foreign generation and on idle.
    func testPendingRejectedForForeignGenerationOrIdle() {
        let gate = DictationCancelGate()
        let gen1 = gate.beginSession()
        gate.markPendingFinalization(gen: gen1 &+ 100)
        XCTAssertEqual(gate.phase, .recording, "foreign generation must not move the phase")
        gate.cancel()
        gate.markPendingFinalization(gen: gen1)
        XCTAssertFalse(gate.canCancel, "idle must stay idle")
    }

    // Denied insertion: the production decision routes to no-history/no-success.
    func testFocusRejectedInsertionDecisionHasNoSuccessOutcome() {
        XCTAssertEqual(
            DictationController.insertionDecision(focusAllowed: false),
            .focusRejectedNoHistory,
            "rejected insertion must not be recorded as success"
        )
        XCTAssertEqual(
            DictationController.insertionDecision(focusAllowed: true),
            .insertAndRecord
        )
    }
}
