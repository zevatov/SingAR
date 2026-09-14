import Foundation

// MARK: - Этап 3: Nonisolated pure seams (вынесены из DictationController.swift)
//
// Расширение НЕ меняет ни изоляцию, ни API: вложенные типы и статические
// члены остаются доступны как `DictationController.xxx` (все gate-тесты
// Этапов 0–2 вызывают их через имя контроллера и не тронуты).
// `@MainActor`-изоляция контроллера наследуется этим расширением;
// `nonisolated` на каждом члене сохранён явно.

extension DictationController {

    /// Gate 2.6: production finalize decision — history/success HUD only for a
    /// genuinely allowed insertion attempt; rejected focus ⇒ no success.
    /// Этап 2: `nonisolated` — pure decision без состояния, тесты без main.
    enum FinalInsertionDecision: Equatable {
        case insertAndRecord
        case focusRejectedNoHistory
    }
    nonisolated static func insertionDecision(focusAllowed: Bool) -> FinalInsertionDecision {
        focusAllowed ? .insertAndRecord : .focusRejectedNoHistory
    }

    /// PRE-DMG-FIX-CAP: production decision (regression-tested): a snapshot
    /// bounded by the local capture budget must NEVER feed the cloud passes —
    /// their text would cover only the first `AudioRecorder.maxCapturedFrames`
    /// frames and destructively replace the complete live draft.
    /// Этап 2: `nonisolated` — pure decision без состояния, тесты без main.
    nonisolated static func truncatedSnapshotSkipsCloud(snapshotTruncated: Bool) -> Bool {
        snapshotTruncated
    }

    /// Этап 2: pure-seam разделения флага кормления движков и отображения
    /// подсказок. Сегодня оба следуют `livePartials` (паритет поведения);
    /// раздельные входы — для будущих гашений без остановки движков.
    nonisolated static func resolveLiveFlags(livePartials: Bool) -> (feedsEngines: Bool, showsLiveHints: Bool) {
        (livePartials, livePartials)
    }

    // MARK: FIX-A — visible start-refusal feedback (regression-tested seam)
    //
    // A fail-closed AX capture refusal used to return BEFORE the capsule was
    // ever shown (menu-bar flash only), so a hotkey press looked dead. The
    // refusal now surfaces an honest failed capsule + status through the
    // EXISTING indicator mechanism. Presentation only: no session, no writes,
    // no capture fallback — the gate's verdict stays authoritative.

    /// Human-readable, content-free reason for a refused start (one generic
    /// message for every fail-closed denial reason).
    /// Этап 2: `nonisolated` — константы/чистые решения без состояния.
    nonisolated static let startRefusalMessage = "Кликните в текстовое поле и повторите"

    /// FIX-STEP1: discriminated refusal cause (presentation only). The
    /// fail-closed gate verdict stays authoritative; only the capsule text
    /// and the cause log line differ.
    enum StartRefusalReason: Equatable {
        case axDenied
        case focusOrSecureInput
    }

    /// FIX-STEP1 message for the accessibility-denied refusal.
    nonisolated static let axDeniedRefusalMessage = "Нужен доступ: Настройки → Конфиденциальность → Универсальный доступ"

    /// FIX-STEP1 decision (regression-tested): an explicit accessibility
    /// denial surfaces the Settings path; every other fail-closed denial
    /// (secure input, no focused element, non-settable target) keeps the
    /// original generic message. `unknown`/`granted` fail closed to the
    /// generic path (never claims an AX problem it cannot prove).
    nonisolated static func refusalReason(axStatus: PermissionStatus) -> StartRefusalReason {
        axStatus == .denied ? .axDenied : .focusOrSecureInput
    }

    /// FIX-STEP1 decision (regression-tested): capsule message for a given
    /// accessibility status. Takes the status as a plain value so the decision
    /// is unit-testable without touching real AX APIs.
    nonisolated static func refusalMessage(axStatus: PermissionStatus) -> String {
        refusalReason(axStatus: axStatus) == .axDenied
            ? axDeniedRefusalMessage
            : startRefusalMessage
    }

    /// The refusal capsule auto-hides on the same 1.2s window every other
    /// failure path already uses.
    nonisolated static let refusalFeedbackHideDelay: TimeInterval = 1.2

    /// FIX-A decision (regression-tested): a refused capture must still give
    /// visible feedback; a successful capture must never show refusal UI.
    nonisolated static func showsRefusalFeedback(captureSucceeded: Bool) -> Bool {
        !captureSucceeded
    }
}
