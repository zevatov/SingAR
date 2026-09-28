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

    /// Human-readable, content-free reason for a refused start (generic
    /// message when AX is not denied and SingAR is not frontmost).
    /// Этап 2: `nonisolated` — константы/чистые решения без состояния.
    nonisolated static let startRefusalMessage = "Кликните в текстовое поле и повторите"

    /// FIX-B1: discriminated refusal cause (presentation only). The
    /// fail-closed gate verdict stays authoritative; only the capsule text
    /// and the cause log line differ.
    enum StartRefusalReason: Equatable {
        case axDenied
        case selfFrontmost
        case focusOrSecureInput
    }

    /// FIX-STEP1 message for the accessibility-denied refusal.
    nonisolated static let axDeniedRefusalMessage = "Нужен доступ: Настройки → Конфиденциальность → Универсальный доступ"

    /// FIX-B1: SingAR itself is frontmost, so the probe cannot capture a
    /// foreign editable target. Presentation only — no capture fallback.
    nonisolated static let selfFrontmostRefusalMessage = "Окно SingAR в фокусе — кликните в поле целевого приложения"

    /// FIX-B1 decision (regression-tested): explicit AX denial wins; else a
    /// self-frontmost window gets the dedicated hint; every other fail-closed
    /// denial (secure input, no focused element, non-settable / non-whitelisted
    /// role) keeps the generic message. `unknown`/`granted` never claim an AX
    /// problem they cannot prove. Default `selfIsFrontmost: false` keeps the
    /// FIX-STEP1 call sites source-compatible.
    nonisolated static func refusalReason(
        axStatus: PermissionStatus,
        selfIsFrontmost: Bool = false
    ) -> StartRefusalReason {
        if axStatus == .denied { return .axDenied }
        if selfIsFrontmost { return .selfFrontmost }
        return .focusOrSecureInput
    }

    /// FIX-B1 decision (regression-tested): capsule message for a given
    /// accessibility status and whether SingAR is the frontmost app. Takes
    /// plain values so the decision is unit-testable without real AX APIs.
    nonisolated static func refusalMessage(
        axStatus: PermissionStatus,
        selfIsFrontmost: Bool = false
    ) -> String {
        switch refusalReason(axStatus: axStatus, selfIsFrontmost: selfIsFrontmost) {
        case .axDenied:
            return axDeniedRefusalMessage
        case .selfFrontmost:
            return selfFrontmostRefusalMessage
        case .focusOrSecureInput:
            return startRefusalMessage
        }
    }

    /// Stable start-refusal code for the pipeline log. AX denial wins, then
    /// secure input, then a self-frontmost window; every other fail-closed
    /// denial stays `focus_unverifiable`. No user content.
    nonisolated static func startRefusalErrorCode(
        reason: StartRefusalReason,
        processTrusted: Bool,
        secureInput: Bool
    ) -> String {
        if reason == .axDenied || !processTrusted { return "ax_unavailable" }
        if secureInput { return "secure_input" }
        switch reason {
        case .axDenied:
            return "ax_unavailable"
        case .selfFrontmost:
            return "self_frontmost"
        case .focusOrSecureInput:
            return "focus_unverifiable"
        }
    }

    /// FIX-B2: content-free diagnostic line after a refused capture.
    /// Logs AX role + settable flag only — never value/title/document text.
    nonisolated static func refusalDiagnosticsLog(role: String?, settable: Bool?) -> String {
        guard let settable else {
            return "capture refused diagnostics: facts=nil"
        }
        return "capture refused diagnostics: role=\(role ?? "nil") settable=\(settable)"
    }

    /// The refusal capsule auto-hides on the same 1.2s window every other
    /// failure path already uses.
    nonisolated static let refusalFeedbackHideDelay: TimeInterval = 1.2

    /// FIX-A decision (regression-tested): a refused capture must still give
    /// visible feedback; a successful capture must never show refusal UI.
    nonisolated static func showsRefusalFeedback(captureSucceeded: Bool) -> Bool {
        !captureSucceeded
    }

    /// Status shown in the capsule when Whisper returned nothing usable and
    /// there is no live/local text to keep. Status only — never a draft.
    nonisolated static let emptyRecognitionStatus = "Ничего не распознано"

    /// Status shown next to an inserted transcript when polish timed out or
    /// the polish service failed. The raw text is what gets inserted.
    nonisolated static let unpolishedInsertStatus = "Текст без правки"

    /// Whisper empty/error must not wipe a non-empty live draft or local
    /// transcript. Whitespace-only values count as empty. A still-empty result
    /// is not inserted; the caller surfaces `emptyRecognitionStatus`.
    nonisolated static func whisperFallbackText(liveOrLocal: String, cloudText: String) -> String {
        let cloud = cloudText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cloud.isEmpty { return cloud }
        return liveOrLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polish failures that keep the raw transcript and must say so in the
    /// capsule. Other polish errors keep their existing dedicated messages.
    nonisolated static func polishNeedsUnpolishedStatus(_ error: CloudASRError?) -> Bool {
        switch error {
        case .timeout?, .serverError?:
            return true
        default:
            return false
        }
    }
}
