import Foundation

/// Phases of one dictation session relevant to Esc-cancellability (Gate 2.6).
enum DictationCancelPhase: Equatable {
    case idle
    case recording
    /// stopDictation ran; the 120ms hand-off / cloud finalize pass is in
    /// flight and `finalizeTask` may not be installed yet.
    case pendingFinalization
    case finalizing
}

/// Session-scoped Esc-cancellability state machine (Gate 2.6).
///
/// `canCancel` must stay true continuously across recording → stop → finalize
/// processing and return to false only on idle. The pending window is opened
/// SYNCHRONOUSLY by `markPendingFinalization` inside stopDictation (before the
/// 120ms hand-off delay), closing the gap where `finalizeTask` was still nil
/// and Esc never reached `cancelDictation`. Transitions are generation-checked
/// so a stale finalize can never reset a newer session's window.
///
/// Main-thread only: the controller mutates it from its main-thread paths.
final class DictationCancelGate {
    private(set) var generation = 0
    private(set) var phase: DictationCancelPhase = .idle

    /// Esc routing gate: true while recording, while the finalize hand-off is
    /// pending, and while the finalize Task is in flight. Idle is exempt.
    var canCancel: Bool { phase != .idle }

    /// Starts a new session: bumps the generation, opens the recording window
    /// and drops any stale pending-finalization window from a prior session.
    @discardableResult
    func beginSession() -> Int {
        generation &+= 1
        phase = .recording
        return generation
    }

    /// stopDictation: opens the pending window synchronously BEFORE the
    /// finalize hand-off delay.
    func markPendingFinalization(gen: Int) {
        guard gen == generation, phase == .recording else { return }
        phase = .pendingFinalization
    }

    /// finalizeTask installed on the main queue — the window stays open via
    /// the `.finalizing` phase until the natural end.
    func finalizeTaskInstalled(gen: Int) {
        guard gen == generation, phase == .pendingFinalization else { return }
        phase = .finalizing
    }

    /// Natural finalize end (commit success or error). Generation-checked: a
    /// stale finish must not clear a newer session's window.
    func finalizeFinished(gen: Int) {
        guard gen == generation else { return }
        phase = .idle
    }

    /// Esc: closes the window and bumps the generation so late async cleanup
    /// (the 120ms block and the finalize Task) fails its generation guards.
    /// Returns true when an active window was actually consumed.
    @discardableResult
    func cancel() -> Bool {
        let hadActiveWindow = phase != .idle
        generation &+= 1
        phase = .idle
        return hadActiveWindow
    }
}
