import AppKit
import AVFoundation
import ApplicationServices

/// Orchestrates real-time live typing dictation:
/// hotkey → live microphone capture → real-time keystroke typing into active app → instant release & high-precision Gemini 3.5 audio polish.
final class DictationController {

    private let statusBar: StatusBarController
    private let settings = AppSettings.shared

    private let audio = AudioRecorder()
    private let vad = VoiceActivityDetector()
    private let injector = TextInjector()
    private let media = MediaController()
    private let commands = VoiceCommandParser()

    private var localAsr = SpeechEngine()
    private var geminiAsr: GeminiLiveEngine?
    private let cloud = CloudASR()
    private let indicator = DictationIndicator()
    private let history = DictationHistory.shared

    private var isDictating = false
    // Session-scoped pause marker bound to the session generation. The
    // isMediaPlaying callback is delivered asynchronously; binding it to the
    // generation (and to a live session) prevents a late callback from arming
    // a resume for a newer session or one that already resumed.
    private var pausedMediaGeneration: Int?
    private var recordingStartedAt = Date()

    // Live typing state
    private var lastLiveText = ""
    private var hasLiveTyped = false

    private var focusCheckTimer: Timer?
    private var sessionGeneration = 0
    private var finalizeTask: Task<Void, Never>?
    // Generation captured by the last stopDictation; used to detect the
    // stop→finalize hand-off window in cancelDictation.
    private var lastStoppedGeneration = 0
    // Gate 2.6: session-scoped Esc-cancellability. Opened synchronously at
    // stop (before the 120ms hand-off), closed on cancel/success/error/new
    // start; generation-checked against stale late cleanup.
    private let cancelGate = DictationCancelGate()
    var canCancel: Bool { cancelGate.canCancel }
    // PRE-DMG-FIX: session-scoped fail-closed target ownership. The gate
    // captures ONE verified editable element per session and re-verifies it
    // before every mutation; any unverifiable state denies (no bundle
    // fallback for writes).
    private let focusTargetGate = DictationFocusTargetGate()

    /// Gate 2.6: production finalize decision — history/success HUD only for a
    /// genuinely allowed insertion attempt; rejected focus ⇒ no success.
    enum FinalInsertionDecision: Equatable {
        case insertAndRecord
        case focusRejectedNoHistory
    }
    static func insertionDecision(focusAllowed: Bool) -> FinalInsertionDecision {
        focusAllowed ? .insertAndRecord : .focusRejectedNoHistory
    }

    /// PRE-DMG-FIX-CAP: production decision (regression-tested): a snapshot
    /// bounded by the local capture budget must NEVER feed the cloud passes —
    /// their text would cover only the first `AudioRecorder.maxCapturedFrames`
    /// frames and destructively replace the complete live draft.
    static func truncatedSnapshotSkipsCloud(snapshotTruncated: Bool) -> Bool {
        snapshotTruncated
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
    static let startRefusalMessage = "Кликните в текстовое поле и повторите"

    /// FIX-STEP1: discriminated refusal cause (presentation only). The
    /// fail-closed gate verdict stays authoritative; only the capsule text
    /// and the cause log line differ.
    enum StartRefusalReason: Equatable {
        case axDenied
        case focusOrSecureInput
    }

    /// FIX-STEP1 message for the accessibility-denied refusal.
    static let axDeniedRefusalMessage = "Нужен доступ: Настройки → Конфиденциальность → Универсальный доступ"

    /// FIX-STEP1 decision (regression-tested): an explicit accessibility
    /// denial surfaces the Settings path; every other fail-closed denial
    /// (secure input, no focused element, non-settable target) keeps the
    /// original generic message. `unknown`/`granted` fail closed to the
    /// generic path (never claims an AX problem it cannot prove).
    static func refusalReason(axStatus: PermissionStatus) -> StartRefusalReason {
        axStatus == .denied ? .axDenied : .focusOrSecureInput
    }

    /// FIX-STEP1 decision (regression-tested): capsule message for a given
    /// accessibility status. Takes the status as a plain value so the decision
    /// is unit-testable without touching real AX APIs.
    static func refusalMessage(axStatus: PermissionStatus) -> String {
        refusalReason(axStatus: axStatus) == .axDenied
            ? axDeniedRefusalMessage
            : startRefusalMessage
    }

    /// The refusal capsule auto-hides on the same 1.2s window every other
    /// failure path already uses.
    static let refusalFeedbackHideDelay: TimeInterval = 1.2

    /// FIX-A decision (regression-tested): a refused capture must still give
    /// visible feedback; a successful capture must never show refusal UI.
    static func showsRefusalFeedback(captureSucceeded: Bool) -> Bool {
        !captureSucceeded
    }

    var onFocusLost: (() -> Void)?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    private func showIndicatorNearStatusBar() {
        let point: NSPoint
        if let frame = statusBar.statusItemButtonFrame {
            point = NSPoint(x: frame.midX, y: frame.maxY)
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            point = NSPoint(x: screen.visibleFrame.maxX - 120, y: screen.visibleFrame.maxY)
        } else {
            point = NSPoint(x: 200, y: 200)
        }
        indicator.show(near: point)
    }

    // MARK: Public (called by HotkeyManager)

    func startDictation() {
        guard settings.enabled, !isDictating else {
            NSLog("[SingAR] startDictation skipped: enabled=\(settings.enabled) isDictating=\(isDictating)")
            return
        }

        isDictating = true
        sessionGeneration &+= 1
        // PRE-DMG-FIX: fail-closed capture AFTER the generation bump — the
        // target is bound to this session's generation from the start. No
        // verified editable target ⇒ refuse to start (no session, no writes).
        // The bumped generation is KEPT: a failed start still invalidates any
        // prior session's stale finalize, which can then never pass its
        // generation guard against the current controller state.
        let captureSucceeded = focusTargetGate.captureSessionTarget(generation: sessionGeneration)
        guard captureSucceeded else {
            // FIX-STEP1: discriminate the refusal CAUSE (presentation + log
            // only). The gate verdict above stays authoritative — this is a
            // double-check of the accessibility status AFTER the refusal, so
            // an explicitly denied AX surfaces the Settings path instead of
            // the generic "focus the field" hint.
            let axStatus = PermissionChecker.shared.status(of: .accessibility)
            let refusalMessage = Self.refusalMessage(axStatus: axStatus)
            NSLog("[SingAR] no AX-verifiable editable target — not starting dictation")
            // FIX-STEP1: the refusal cause goes to singar.log too (AppLogger
            // itself mirrors into NSLog). Content-free: status only.
            switch Self.refusalReason(axStatus: axStatus) {
            case .axDenied:
                AppLogger.shared.log("capture refused: axUnavailable")
            case .focusOrSecureInput:
                AppLogger.shared.log("capture refused: focus/secureInput")
            }
            focusTargetGate.invalidate(generation: sessionGeneration)
            cancelGate.cancel()
            finalizeTask?.cancel()
            finalizeTask = nil
            isDictating = false
            onFocusLost?()
            // FIX-A: the pre-fix path returned here with only a menu-bar flash
            // BEFORE the capsule was ever shown, so the hotkey press looked
            // dead. Surface the refusal through the existing failed-capsule
            // mechanism and auto-hide it like every other failure path.
            // Fail-closed behavior above is UNCHANGED (no fallback capture).
            if Self.showsRefusalFeedback(captureSucceeded: captureSucceeded) {
                let gen = sessionGeneration
                statusBar.setStatus(.failed)
                indicator.setStatus(.failed, message: refusalMessage)
                showIndicatorNearStatusBar()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.refusalFeedbackHideDelay) { [weak self] in
                    guard let self, self.sessionGeneration == gen, !self.isDictating else { return }
                    self.indicator.hide()
                    self.statusBar.setStatus(.idle)
                }
            }
            return
        }
        // Gate 2.6: new start drops any stale pending window for its own
        // generation and opens the fresh recording window.
        cancelGate.beginSession()
        // A previous session's finalization must never outlive into this one.
        finalizeTask?.cancel()
        finalizeTask = nil
        recordingStartedAt = Date()
        lastLiveText = ""
        hasLiveTyped = false
        logStage("recording", startedAt: recordingStartedAt)

        // Smart Media Pause (immediately pause, track if playback was active)
        if settings.pauseMedia {
            let gen = sessionGeneration
            media.isMediaPlaying { [weak self] isPlaying in
                // Only the live session may claim the pause marker: a callback
                // landing after stop/cancel (or a newer session's start) must
                // never arm a later resume.
                guard let self, isPlaying, self.isDictating, self.sessionGeneration == gen else { return }
                self.pausedMediaGeneration = gen
            }
            media.pauseBackgroundMedia()
        }

        vad.reset()
        statusBar.setStatus(.listening)
        indicator.setStatus(.listening)
        startFocusMonitoring()

        // PRE-DMG-FIX: a new generation invalidates any older captured target.
        focusTargetGate.invalidate(generation: sessionGeneration &- 1)
        showIndicatorNearStatusBar()
        vad.onLevel = { [weak self] level in
            self?.indicator.setLevel(level)
        }

        // Initialize engines
        localAsr = SpeechEngine()
        if settings.livePartials && settings.cloudModel == .gemini35Transcribe && cloud.available {
            geminiAsr = GeminiLiveEngine()
        } else {
            geminiAsr = nil
        }

        SoundFeedback.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isDictating else { return }
            // PRE-DMG-FIX-CAP: the recorder's limit flag belongs to the
            // PREVIOUS session — clear it together with the session snapshot
            // BEFORE this session starts feeding audio.
            self.audio.clearCapturedBuffers()
            // PRE-DMG-FIX-CAP: generation-scoped auto-finalize. Only THIS
            // session's edge-crossing may stop it; a stale callback arriving
            // after stop/cancel or during a newer session is ignored. The
            // callback itself fires on main (recorder guarantees it), so
            // calling stopDictation() here never touches AVAudioEngine from
            // the realtime tap thread.
            let gen = self.sessionGeneration
            self.audio.onCaptureLimitReached = { [weak self] in
                guard let self, self.isDictating, self.sessionGeneration == gen else {
                    AppLogger.shared.log("⏳ capture budget callback dropped: stale or inactive session (gen=\(gen))")
                    return
                }
                AppLogger.shared.log("⏳ capture budget reached (local safety budget) — finalizing with the full live draft, no truncation")
                self.indicator.setStatus(.recognizing, message: "Достигнут предел записи — финализация")
                self.stopDictation()
            }
            self.audio.start { [weak self] buffer in
                guard let self, self.isDictating else { return }
                self.vad.feed(buffer)

                // Feed real-time speech engine with live typing callback ONLY if livePartials is enabled
                if self.settings.livePartials {
                    if let gemini = self.geminiAsr {
                        gemini.feed(buffer) { [weak self] partial in
                            guard let self, self.isDictating else { return }
                            DispatchQueue.main.async {
                                if !partial.isEmpty {
                                    self.handleLivePartial(partial)
                                }
                            }
                        }
                    } else {
                        self.localAsr.feed(buffer) { [weak self] partial in
                            guard let self, self.isDictating else { return }
                            DispatchQueue.main.async {
                                self.handleLivePartial(partial)
                            }
                        }
                    }
                }
            }
        }
    }

    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        stopFocusMonitoring()

        let gen = sessionGeneration
        lastStoppedGeneration = gen
        // Gate 2.6: open the pending-finalization window SYNCHRONOUSLY, before
        // the 120ms hand-off, so Esc in that window still reaches cancel.
        cancelGate.markPendingFinalization(gen: gen)
        let transcribingStartedAt = Date()
        let recordingDurationMs = Int(Date().timeIntervalSince(recordingStartedAt) * 1000)
        logStage("recording", startedAt: recordingStartedAt, completed: true)
        logStage("transcribing", startedAt: transcribingStartedAt)

        SoundFeedback.stop()
        resumeMediaIfNeeded()

        // Transition to Processing state in both capsule indicator and status bar
        statusBar.setStatus(.recognizing)
        indicator.setStatus(.recognizing)

        // Immutable snapshot of THIS session's audio, taken synchronously and
        // bound to `gen` before any async work starts. Without it, a
        // startDictation() racing inside the 120ms window could either
        // clearCapturedBuffers() (engine already stopped → new session wipes
        // the old data before the delayed read) or keep the same engine
        // running with no clear (start is a no-op while isRunning), appending
        // new-session frames into the same store → cross-session mixing.
        // The local `let captured` copy is immune to both: clearCapturedBuffers()
        // and appends only mutate the recorder's own array.
        let captured = audio.capturedBuffers
        // Stop the tap synchronously so post-stop frames can never cross the
        // session boundary into the next dictation's buffer store. Idempotent:
        // `stop()` guards on isRunning.
        audio.stop()

        // Short delay before finalize keeps prior timing parity; the audio
        // snapshot is already fixed and immune to a racing new session.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.sessionGeneration == gen else { return }

            let finalize = Task { [weak self] in
                guard let self else { return }
                let (localAsr, geminiAsr) = (self.localAsr, self.geminiAsr)
                var provider = "live"
                var model = self.settings.cloudModel.rawValue

                // 1. Gather live text from engines
                async let localFinal = localAsr.finalize()
                async let geminiFinal = geminiAsr?.finalize() ?? ""

                let l = await localFinal
                let g = await geminiFinal

                var transcript = !g.isEmpty ? g : l
                if transcript.isEmpty {
                    transcript = self.lastLiveText
                }
                // PRE-DMG-FIX-CAP: at the moment the audio snapshot was taken
                // the capture budget may already have been crossed (engine
                // auto-stopped ⇒ transcript provably cannot cover the whole
                // session). A successful cloud pass then returns text for the
                // FIRST `AudioRecorder.maxCapturedFrames` only; replacing the
                // (longer) live draft with it would silently lose audio past
                // the edge. Fail-closed: keep the COMPLETE live/local text,
                // skip both cloud passes (no truncated cloud history), and
                // surface an honest warning.
                let snapshotTruncated = self.audio.didReachCaptureLimit

                var finalText = self.processed(transcript)
                AppLogger.shared.log("📝 stopDictation: audioRecorded=\(recordingDurationMs)ms, buffers=\(captured.count), liveText=\(AppLogger.redactedPreview(finalText)), cloudModel=\(self.settings.cloudModel.rawValue), cloudCleanup=\(self.settings.cloudCleanup)")

                // 2. High-precision Primary ASR pass (Local Whisper Turbo, Gemini 3.5, OpenRouter, Groq)
                guard self.sessionGeneration == gen, !Task.isCancelled else { return }
                // Gate 2.6: finalize Task is installed for this generation.
                await MainActor.run { self.cancelGate.finalizeTaskInstalled(gen: gen) }
                // Gate 1.7: typed cloud outcome. Any failure keeps the fallback
                // contract — finalText already holds live/local text, so the
                // session still commits the usable fallback (Gate 0 behavior,
                // provider stays "live" so history shows no cloud success).
                var cloudError: CloudASRError?
                // Gate 2.5: typed polish failure reason; declared here so the
                // MainActor UI block below can see it (nil when polish
                // succeeded or was skipped).
                var polishError: CloudASRError?
                var captureBudgetTruncatedCommit = false
                if Self.truncatedSnapshotSkipsCloud(snapshotTruncated: snapshotTruncated) {
                    AppLogger.shared.log("⛔️ stopDictation: snapshot bounded at local capture budget — skipping cloud passes to keep the FULL live text (no truncated replacement)")
                    captureBudgetTruncatedCommit = true
                } else if self.cloud.available, let audioData = WAVWriter.wavData(from: captured) {
                    AppLogger.shared.log("🎧 stopDictation: WAV generated OK, size=\(audioData.count) bytes, running \(self.settings.cloudModel.rawValue)...")
                    let asrStart = Date()
                    let asrOutcome = await self.cloud.cloudTranscribeResult(audio: audioData)
                    if case .success(let transcribed) = asrOutcome {
                        let asrElapsed = Int(Date().timeIntervalSince(asrStart) * 1000)
                        AppLogger.shared.log("✅ stopDictation: ASR finished in \(asrElapsed)ms: transcribed=\(AppLogger.redactedPreview(transcribed))")

                        var polishedText: String?
                        // 3. Optional Vibe-Coder polish pass
                        guard self.sessionGeneration == gen, !Task.isCancelled else { return }
                        if self.settings.cloudCleanup {
                            let polishStart = Date()
                            // Gate 2.5: typed polish outcome; ANY failure falls
                            // back to the unpolished transcript (Gate 0 behavior).
                            switch await self.cloud.polishResult(text: transcribed) {
                            case .success(let p):
                                polishedText = p
                                AppLogger.shared.log("✨ stopDictation: Polish finished in \(Int(Date().timeIntervalSince(polishStart) * 1000))ms: polished=\(AppLogger.redactedPreview(p))")
                            case .failure(let pe):
                                polishError = pe
                                AppLogger.shared.log("⚠️ stopDictation: polish failed (\(pe)) in \(Int(Date().timeIntervalSince(polishStart) * 1000))ms — using unpolished text")
                            }
                        }

                        if let polished = polishedText, !polished.isEmpty {
                            finalText = self.processed(polished)
                            provider = self.settings.cloudModel.rawValue + "+polish"
                        } else {
                            finalText = self.processed(transcribed)
                            provider = self.settings.cloudModel.rawValue
                        }
                        model = self.settings.cloudModel.rawValue
                    } else {
                        if case .failure(let e) = asrOutcome { cloudError = e }
                        AppLogger.shared.log("⚠️ stopDictation: cloudTranscribe failed (\(String(describing: cloudError))) — using live/local text")
                    }
                } else {
                    AppLogger.shared.log("⚠️ stopDictation: cloud not available or WAV nil (available=\(self.cloud.available), captured=\(captured.count))")
                }

                let textToCommit = finalText
                let recordedProvider = provider
                let recordedModel = model
                let truncationWarning = captureBudgetTruncatedCommit
                let finalCloudError = cloudError
                let finalPolishError = polishError

                await MainActor.run {
                    guard self.sessionGeneration == gen, !Task.isCancelled else { return }
                    self.finalizeTask = nil
                    self.logStage("transcribing", startedAt: transcribingStartedAt, completed: true)

                    // Gate 2.6: the finalize attempt ends exactly once — with
                    // an allowed insertion (record success) or with a rejected
                    // focus (no history, no success HUD). CGEvent delivery is
                    // NOT confirmed here; only the attempt-gate is applied.
                    // PRE-DMG-FIX: final insertion requires THIS session's
                    // captured target, re-verified now (PID + semantic
                    // identity + settable). No bundle fallback.
                    switch Self.insertionDecision(focusAllowed: self.focusTargetGate.canMutate(generation: gen) == nil) {
                    case .insertAndRecord:
                        break
                    case .focusRejectedNoHistory:
                        AppLogger.shared.log("⏹ stopDictation: captured target no longer verifiable (foreign/unavailable/secure) — final insertion rejected, no history/success")
                        self.statusBar.setStatus(.failed)
                        self.indicator.setStatus(.failed)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            guard let self, self.sessionGeneration == gen else { return }
                            self.indicator.hide()
                            self.statusBar.setStatus(.idle)
                        }
                        self.cancelGate.finalizeFinished(gen: gen)
                        return
                    }

                    let totalLatencyMs = Int(Date().timeIntervalSince(self.recordingStartedAt) * 1_000)
                    AppLogger.shared.log("⌨️ INJECTING FINAL TEXT \(AppLogger.redactedPreview(textToCommit)) (provider: \(recordedProvider), model: \(recordedModel), totalLatency: \(totalLatencyMs)ms)")

                    if !textToCommit.isEmpty {
                        self.statusBar.setStatus(.inserting)
                        self.indicator.setStatus(.inserting)

                        // PRE-DMG-FIX: the live draft may only be erased via a
                        // verified owned-range; without a provable ownership
                        // window the destructive replace is denied (fail-closed,
                        // draft stays, no history regression: decision already
                        // recorded the attempt — but a denied erase must NOT be
                        // a success. Append-only path injects after the draft).
                        if self.hasLiveTyped && !self.lastLiveText.isEmpty {
                            switch self.focusTargetGate.verifiedOwnedRange(generation: gen, ownedText: self.lastLiveText) {
                            case .success(let ownedRange):
                                self.applyPolishedText(textToCommit, ownedRange: ownedRange)
                                // PRE-DMG-D1-FIX: success-history is recorded
                                // ONLY after a verified insert/replace actually
                                // happened; a verifiedOwnedRange .failure below
                                // must leave no success entry.
                                self.history.append(DictationHistoryEntry(
                                    timestamp: Date(),
                                    provider: recordedProvider,
                                    model: recordedModel,
                                    latencyMs: totalLatencyMs,
                                    text: textToCommit
                                ))
                            case .failure(let denial):
                                if denial == .selectionUnavailable && self.focusTargetGate.canMutate(generation: gen) == nil {
                                    AppLogger.shared.log("ℹ️ final replace: editor without AX selection — applying draft replacement directly")
                                    self.applyPolishedText(textToCommit, ownedRange: NSRange(location: 0, length: (self.lastLiveText as NSString).length))
                                    self.history.append(DictationHistoryEntry(
                                        timestamp: Date(),
                                        provider: recordedProvider,
                                        model: recordedModel,
                                        latencyMs: totalLatencyMs,
                                        text: textToCommit
                                    ))
                                } else {
                                    AppLogger.shared.log("⏹ final replace: owned-range not verifiable (\(denial.rawValue)) — draft preserved, no destructive erase")
                                    self.statusBar.setStatus(.failed)
                                    self.indicator.setStatus(.failed)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                                        guard let self, self.sessionGeneration == gen else { return }
                                        self.indicator.hide()
                                        self.statusBar.setStatus(.idle)
                                    }
                                    self.cancelGate.finalizeFinished(gen: gen)
                                    return
                                }
                            }
                        } else {
                            self.injector.insert(textToCommit)
                            // PRE-DMG-D1-FIX: same success-only contract for
                            // the plain (no live draft) injection path.
                            self.history.append(DictationHistoryEntry(
                                timestamp: Date(),
                                provider: recordedProvider,
                                model: recordedModel,
                                latencyMs: totalLatencyMs,
                                text: textToCommit
                            ))
                        }

                        // Gate 2.6: finalize ended successfully — close the
                        // Esc window for this generation.
                        self.cancelGate.finalizeFinished(gen: gen)

                        // Gate 2.5: actionable polish failure (invalidKey /
                        // rateLimited / network) surfaces a dedicated capsule
                        // message — same contract as Gate 1.7; every other
                        // polish error falls back silently, the unpolished
                        // text is already committed above.
                        let polishSurfaced = finalPolishError?.showsDedicatedMessage ?? false
                        // PRE-DMG-FIX-CAP: honest post-commit warning that the
                        // recording was bounded by the local budget; the
                        // committed text is the complete live draft.
                        let budgetSurfaced = truncationWarning
                        if budgetSurfaced {
                            self.statusBar.setStatus(.failed)
                            self.indicator.setStatus(.failed, message: "Запись остановлена на лимите — вставлен полный текст")
                        } else if polishSurfaced, let pe = finalPolishError {
                            self.statusBar.setStatus(.failed)
                            self.indicator.setStatus(.failed, message: pe.userMessage)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + ((polishSurfaced || budgetSurfaced) ? 1.2 : 0.35)) { [weak self] in
                            guard let self, self.sessionGeneration == gen else { return }
                            self.indicator.hide()
                            self.statusBar.setStatus(.idle)
                        }
                    } else {
                        self.statusBar.setStatus(.failed)
                        // Gate 1.7: actionable cloud errors (invalidKey /
                        // rateLimited / network) get a human-readable capsule
                        // message; everything else keeps the generic label.
                        if let ce = finalCloudError, ce.showsDedicatedMessage {
                            self.indicator.setStatus(.failed, message: ce.userMessage)
                        } else {
                            self.indicator.setStatus(.failed)
                        }
                        // Gate 2.6: empty commit is a finalize end — close the
                        // Esc window for this generation.
                        self.cancelGate.finalizeFinished(gen: gen)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            guard let self, self.sessionGeneration == gen else { return }
                            self.indicator.hide()
                            self.statusBar.setStatus(.idle)
                        }
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == gen else { return }
                self.finalizeTask = finalize
            }
        }
    }

    func cancelDictation() {
        finalizeTask?.cancel()
        finalizeTask = nil
        // PRE-DMG-FIX: the generation whose target/draft is being cancelled —
        // captured before the bump below.
        let genBeforeCancel = sessionGeneration
        sessionGeneration &+= 1
        // Gate 2.6: close the Esc window synchronously and invalidate the
        // generation so a stale finalize/late cleanup cannot reset it.
        cancelGate.cancel()
        let wasDictating = isDictating
        isDictating = false
        stopFocusMonitoring()
        audio.stop()
        SoundFeedback.stop()
        indicator.hide()

        // Gate 0.3 + PRE-DMG-FIX: erase the session-owned live draft only when
        // the session's captured target is still verified AND the caret sits
        // at the end of a provable owned window. Esc-cancellation of the
        // PROCESSING still happens regardless (fail-closed erase ≠ fail-open
        // cancel); an unverifiable draft is left in place — honest gap.
        if wasDictating, hasLiveTyped, !lastLiveText.isEmpty {
            switch focusTargetGate.verifiedOwnedRange(generation: genBeforeCancel, ownedText: lastLiveText) {
            case .success(let ownedRange):
                injector.backspace(count: ownedRange.length)
            case .failure(let denial):
                if denial == .selectionUnavailable && focusTargetGate.canMutate(generation: genBeforeCancel) == nil {
                    injector.backspace(count: (lastLiveText as NSString).length)
                } else {
                    NSLog("[SingAR] cancel: owned-range not verifiable (\(denial.rawValue)) — draft left in place, no destructive erase")
                }
            }
        }
        focusTargetGate.invalidate(generation: genBeforeCancel)
        lastLiveText = ""
        hasLiveTyped = false

        // Only cancel engines owned by the recording session; a stale
        // finalization cleanup must not touch a new session's engines.
        if wasDictating {
            localAsr.cancel()
            geminiAsr?.cancel()
        } else if sessionGeneration == lastStoppedGeneration + 1 {
            // Esc in the stop→finalize hand-off window (no finalizeTask yet):
            // the engines still belong to the stopped session, so abort their
            // in-flight work. A newer session installs fresh engines and bumps
            // the generation past lastStoppedGeneration, so this never touches it.
            localAsr.cancel()
            geminiAsr?.cancel()
        }
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
    }

    // MARK: Real-time Live Typing Engine

    private func handleLivePartial(_ newText: String) {
        guard isDictating, settings.livePartials else { return }
        // Gate 1.5 + PRE-DMG-FIX: live keystrokes/backspaces require THIS
        // session's captured, re-verified target right now (PID + semantic
        // identity, trusted AX, no secure input). Foreign/unverifiable ⇒ skip.
        let gen = sessionGeneration
        if let denial = focusTargetGate.canMutate(generation: gen) {
            NSLog("[SingAR] live partial skipped: target not verifiable (\(denial.rawValue))")
            return
        }
        // Guard against user-typed interference inside the owned window: if
        // the editor exposes a value, the session's draft must still be its
        // tail before erasing/retyping anything.
        if let tailDenial = focusTargetGate.verifiedAppendTail(generation: gen, ownedText: lastLiveText) {
            NSLog("[SingAR] live partial skipped: owned tail not verifiable (\(tailDenial.rawValue))")
            return
        }
        let cleaned = processed(newText)
        guard !cleaned.isEmpty, cleaned != lastLiveText else { return }

        // Compute common prefix to minimize backspaces
        let oldChars = Array(lastLiveText)
        let newChars = Array(cleaned)

        var commonPrefixLength = 0
        while commonPrefixLength < oldChars.count &&
              commonPrefixLength < newChars.count &&
              oldChars[commonPrefixLength] == newChars[commonPrefixLength] {
            commonPrefixLength += 1
        }

        let backspacesNeeded = oldChars.count - commonPrefixLength
        let charsToType = String(newChars[commonPrefixLength...])

        NSLog("[SingAR] ⚡️ Live typing partial: %@ (charsToType=\(charsToType.count), backspaces=\(backspacesNeeded))", AppLogger.redactedPreview(cleaned))

        if backspacesNeeded > 0 {
            injector.backspace(count: backspacesNeeded)
            usleep(10000) // 10ms pause between deletions and keystrokes
        }
        if !charsToType.isEmpty {
            injector.typeText(charsToType)
        }

        lastLiveText = cleaned
        hasLiveTyped = true
    }

    /// Guaranteed atomic application of polished text upon dictation finish.
    /// PRE-DMG-FIX: the erase is bounded by the caller's verified owned range
    /// (UTF-16 length equals the draft length in that proof), so backspaces
    /// can never cross outside the session-owned window.
    private func applyPolishedText(_ polished: String, ownedRange: NSRange) {
        guard !polished.isEmpty else { return }
        guard polished != lastLiveText else { return }

        // Safely erase exactly the verified owned window:
        if ownedRange.length > 0 {
            injector.backspace(count: ownedRange.length)
            usleep(25000) // 25ms pause for target editor to cleanly process deletions
        }

        // Atomically paste the clean polished text (zero character drops, zero race conditions)
        injector.insert(polished)
        lastLiveText = polished
    }

    // MARK: Focus Monitoring

    private func startFocusMonitoring() {
        focusCheckTimer?.invalidate()
        focusCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isDictating else { return }
            if let denial = self.focusTargetGate.canMutate(generation: self.sessionGeneration) {
                NSLog("[SingAR] focused target lost (\(denial.rawValue)) — stopping dictation")
                self.onFocusLost?()
                self.stopDictation()
            }
        }
    }

    private func stopFocusMonitoring() {
        focusCheckTimer?.invalidate()
        focusCheckTimer = nil
    }

    // PRE-DMG-FIX: the legacy fail-open textEditorFocused()/frontmost-bundle
    // fallback was removed; all write gating goes through
    // DictationFocusTargetGate (fail-closed, session-scoped).

    // MARK: Post-processing

    private func processed(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if settings.voiceCommands {
            return commands.process(raw)
        }
        return raw
    }

    private func resumeMediaIfNeeded() {
        // Resume only when this session actually confirmed playing media; the
        // marker is consumed so a stale late callback cannot trigger a second
        // resume (cancelDictation has already bumped the generation, hence no
        // generation comparison here — the marker itself is the proof).
        guard pausedMediaGeneration != nil else { return }
        pausedMediaGeneration = nil
        media.resumeBackgroundMedia()
    }

    private func logStage(_ stage: String, startedAt: Date, completed: Bool = false, errorCode: String? = nil) {
        let duration = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let statusStr = completed ? "completed" : "started"
        if let errorCode {
            NSLog("[SingAR] stage=\(stage) status=\(statusStr) duration_ms=\(duration) error_code=\(errorCode)")
        } else {
            NSLog("[SingAR] stage=\(stage) status=\(statusStr) duration_ms=\(duration)")
        }
    }
}
