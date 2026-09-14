import AppKit
import AVFoundation
import ApplicationServices

/// Orchestrates real-time live typing dictation:
/// hotkey → live microphone capture → real-time keystroke typing into active app → instant release & high-precision Gemini 3.5 audio polish.
///
/// Этап 2: `@MainActor`-изолирован — всё состояние сессии (`isDictating`,
/// `sessionGeneration`, `finalizeTask`, `lastLiveText`, ...) мутируется только
/// на main. Realtime tap-поток НЕ трогает это состояние напрямую: в
/// `startDictation` захватываются только thread-safe ссылки (vad/engines/
/// indicator), а живые правки идут пакетно через `TextInjector` (фоновая
/// очередь, main не блокируется). Блокирующие `usleep` на main удалены.
///
/// Этап 3 (декомпозиция, поведение сохранено 1:1): контроллер — тонкий
/// фасад-координатор. Он хранит только session state и делегирует логику
/// extension-файлам того же типа (глобальный актор `@MainActor` действует и
/// на extension-члены, изоляция не ослаблена):
///   - `DictationController+SessionLifecycle.swift` — start/cancel, фокус-
///     мониторинг, media-pause, индикатор/логи (SessionLifecycle).
///   - `DictationController+LiveTypingPipeline.swift` — живые partials,
///     diff/инъекция через `TextInjector`, гашение при focus-shift.
///   - `DictationController+FinalizePipeline.swift` — stop→snapshot→cloud
///     polish→history→HUD (FinalizePipeline).
///   - `DictationController+Seams.swift` — nonisolated pure seams
///     (insertionDecision, truncatedSnapshotSkipsCloud, resolveLiveFlags,
///     startRefusalMessage, refusalReason, refusalMessage,
///     showsRefusalFeedback и др.).
///
/// NOTE: stored-свойства переведены из `private` в module-internal — иначе
/// extension-файлы одного модуля не имеют к ним доступа. Публичный API не
/// расширен (нет `public`), наружу тип по-прежнему не экспортируется
/// (executable target; тесты уже используют `@testable import`).
@MainActor
final class DictationController {

    let statusBar: StatusBarController
    let settings = AppSettings.shared

    let audio = AudioRecorder()
    let vad = VoiceActivityDetector()
    let injector = TextInjector()
    let media = MediaController()
    let commands = VoiceCommandParser()

    var localAsr = SpeechEngine()
    var geminiAsr: GeminiLiveEngine?
    let cloud = CloudASR()
    let indicator = DictationIndicator()
    let history = DictationHistory.shared

    var isDictating = false
    // Session-scoped pause marker bound to the session generation. The
    // isMediaPlaying callback is delivered asynchronously; binding it to the
    // generation (and to a live session) prevents a late callback from arming
    // a resume for a newer session or one that already resumed.
    var pausedMediaGeneration: Int?
    var recordingStartedAt = Date()

    // Live typing state
    var lastLiveText = ""
    var hasLiveTyped = false
    /// Этап 2: два независимых флага вместо одного `livePartials` на две роли.
    /// `feedsEngines` — кормить ли движки кадрами (дорого: SFSpeech/WS);
    /// `showsLiveHints` — показывать ли живые подсказки/печать (дешево: UI).
    /// Сегодня оба = `settings.livePartials` (поведение сохранено), разделение
    /// нужно чтобы тихая сессия/фокус-шифт могли гасить печать не останавливая
    /// движки (и наоборот). Pure-seam `resolveLiveFlags` — offline-тестируемо.
    var feedsEngines = false
    var showsLiveHints = false

    var focusCheckTimer: Timer?
    var sessionGeneration = 0
    var finalizeTask: Task<Void, Never>?
    // Generation captured by the last stopDictation; used to detect the
    // stop→finalize hand-off window in cancelDictation.
    var lastStoppedGeneration = 0
    // Gate 2.6: session-scoped Esc-cancellability. Opened synchronously at
    // stop (before the 120ms hand-off), closed on cancel/success/error/new
    // start; generation-checked against stale late cleanup.
    let cancelGate = DictationCancelGate()
    var canCancel: Bool { cancelGate.canCancel }
    // PRE-DMG-FIX: session-scoped fail-closed target ownership. The gate
    // captures ONE verified editable element per session and re-verifies it
    // before every mutation; any unverifiable state denies (no bundle
    // fallback for writes).
    let focusTargetGate = DictationFocusTargetGate()
    /// Option Б: when focus shifts away in multitasking mode (!stopOnFocusLoss),
    /// live typing is immediately suppressed and the draft erased to prevent lag/freezes.
    var liveTypingSuppressedDueToFocusShift = false

    var onFocusLost: (() -> Void)?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }
}
