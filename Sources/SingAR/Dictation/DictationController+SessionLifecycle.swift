import AppKit
import AVFoundation
import ApplicationServices

// MARK: - Этап 3: SessionLifecycle
//
// Жизненный цикл сессии: старт (fail-closed захват цели, refusal-фидбек,
// media-pause, движки), Esc-отмена, фокус-мониторинг, resume media,
// общие хелперы (индикатор, пост-обработка, stage-логи). Код перенесён из
// `DictationController.swift` 1:1 без изменения поведения (Этап 2 сохранён).
extension DictationController {

    func showIndicatorNearStatusBar() {
        // Этап 2 (M6): унифицировано на `screens.first` как в
        // `DictationIndicator.calculateTargetFrame` — `NSScreen.main`
        // расходился на мультимониторе (main = окно с фокусом, first = экран
        // с меню-баром, куда якорится капсула).
        let point: NSPoint
        if let frame = statusBar.statusItemButtonFrame {
            point = NSPoint(x: frame.midX, y: frame.maxY)
        } else if let screen = NSScreen.screens.first {
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
            // FIX-B1: discriminate the refusal CAUSE (presentation + log
            // only). The gate verdict above stays authoritative — this is a
            // double-check of the accessibility status AFTER the refusal, so
            // an explicitly denied AX surfaces the Settings path instead of
            // the generic "focus the field" hint. Self-frontmost (empty
            // Settings/Onboarding chrome) gets a dedicated hint; no user
            // content is read from the frontmost app.
            let axStatus = PermissionChecker.shared.status(of: .accessibility)
            let selfIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == Bundle.main.bundleIdentifier
            let refusalMessage = Self.refusalMessage(
                axStatus: axStatus,
                selfIsFrontmost: selfIsFrontmost
            )
            NSLog("[SingAR] no AX-verifiable editable target — not starting dictation")
            // FIX-B1: the refusal cause goes to singar.log too (AppLogger
            // itself mirrors into NSLog). Content-free: status only.
            let refusal = Self.refusalReason(axStatus: axStatus, selfIsFrontmost: selfIsFrontmost)
            let refusalCode = Self.startRefusalErrorCode(
                reason: refusal,
                processTrusted: AXIsProcessTrusted(),
                secureInput: LiveAXFocusProbe().isSecureEventInput()
            )
            AppLogger.shared.logPipeline(
                stage: "start",
                code: refusalCode,
                action: "capture_refused",
                reason: refusalCode
            )
            // FIX-B2: second readFocusedFacts is log-only (not a capture).
            // Self-frontmost already returns nil from the live probe.
            // Never log value / window title / document text.
            if let facts = LiveAXFocusProbe().readFocusedFacts() {
                AppLogger.shared.log(
                    Self.refusalDiagnosticsLog(
                        role: facts.identity.role,
                        settable: facts.isValueSettable
                    )
                )
            } else {
                AppLogger.shared.log(Self.refusalDiagnosticsLog(role: nil, settable: nil))
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
        liveTypingSuppressedDueToFocusShift = false
        let liveFlags = Self.resolveLiveFlags(livePartials: settings.livePartials)
        feedsEngines = liveFlags.feedsEngines
        showsLiveHints = liveFlags.showsLiveHints
        injector.cancelPendingRestore()
        logStage("recording", startedAt: recordingStartedAt)

        // Smart Media Pause: only pause if media is actively playing right now
        if settings.pauseMedia {
            let gen = sessionGeneration
            if media.isAnyMediaPlaying() {
                // Audio was actively playing: record generation and pause
                pausedMediaGeneration = gen
                media.pauseBackgroundMedia()
            } else {
                // Audio was already paused: do nothing
                pausedMediaGeneration = nil
            }
        }

        vad.reset()
        statusBar.setStatus(.listening)
        indicator.setStatus(.listening)
        startFocusMonitoring()

        // PRE-DMG-FIX: a new generation invalidates any older captured target.
        focusTargetGate.invalidate(generation: sessionGeneration &- 1)
        showIndicatorNearStatusBar()
        // Этап 2: уровень на главную с троттлингом. VAD `feed` идёт на realtime
        // tap-потоке; `onLevel` вызывается на нём же на КАЖДЫЙ буфер (~100/с).
        // Троттлинг до ~15/с + hop на main: индикатор (`setLevel`) трогает UI
        // только на main (там же `dispatchPrecondition(.onQueue(.main))`).
        // `lastLevelSentAt` живёт на main (колбэк уже на main после hop? нет —
        // VAD зовёт на tap, поэтому троттлинг через lock-free атомик времени:
        // читаем/пишем под main-hop? Проще: дроссель по счётчику буферов —
        // каждый 6-й (~16/с при 100 буф/с) + main-hop. Состояние счётчика —
        // локальная var в замыкании tap-потока (один tap = один поток).
        var levelTick = 0
        vad.onLevel = { [weak self] level in
            levelTick &+= 1
            guard levelTick % 6 == 0 else { return }
            let clamped = max(0, min(1, level))
            DispatchQueue.main.async { [weak self] in
                self?.indicator.setLevel(clamped)
            }
        }

        // Initialize engines: Apple Speech runs ONLY when user explicitly chose localOnly
        if settings.cloudModel == .localOnly {
            localAsr = SpeechEngine()
        } else {
            localAsr = NoopASREngine()
        }
        if feedsEngines && settings.cloudModel == .gemini35Transcribe && cloud.available {
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

                // Этап 2: кормление движков (`feedsEngines`) отделено от показа
                // подсказок (`showsLiveHints`, проверяется в `handleLivePartial`).
                if self.feedsEngines {
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
        injector.cancelPendingRestore()

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
        liveTypingSuppressedDueToFocusShift = false
        feedsEngines = false
        showsLiveHints = false

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

    // MARK: Focus Monitoring

    func startFocusMonitoring() {
        focusCheckTimer?.invalidate()
        if settings.stopOnFocusLoss {
            focusCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.isDictating else { return }
                if let denial = self.focusTargetGate.canMutate(generation: self.sessionGeneration) {
                    NSLog("[SingAR] focused target lost (\(denial.rawValue)) — stopping dictation")
                    self.onFocusLost?()
                    self.stopDictation()
                }
            }
        } else {
            focusCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self, self.isDictating else { return }
                if !self.liveTypingSuppressedDueToFocusShift {
                    if self.focusTargetGate.canMutate(generation: self.sessionGeneration) != nil {
                        self.suppressLiveTypingDueToFocusShift()
                    }
                }
            }
        }
    }

    func stopFocusMonitoring() {
        focusCheckTimer?.invalidate()
        focusCheckTimer = nil
    }

    // PRE-DMG-FIX: the legacy fail-open textEditorFocused()/frontmost-bundle
    // fallback was removed; all write gating goes through
    // DictationFocusTargetGate (fail-closed, session-scoped).

    // MARK: Post-processing (shared: LiveTyping + Finalize pipelines)

    func processed(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if settings.voiceCommands {
            return commands.process(raw)
        }
        return raw
    }

    func resumeMediaIfNeeded() {
        // Resume only when this session actually confirmed playing media; the
        // marker is consumed so a stale late callback cannot trigger a second
        // resume (cancelDictation has already bumped the generation, hence no
        // generation comparison here — the marker itself is the proof).
        guard pausedMediaGeneration != nil else { return }
        pausedMediaGeneration = nil
        media.resumeBackgroundMedia()
    }

    func logStage(_ stage: String, startedAt: Date, completed: Bool = false, errorCode: String? = nil) {
        let duration = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let statusStr = completed ? "completed" : "started"
        if let errorCode {
            AppLogger.shared.logPipeline(
                stage: stage,
                code: errorCode,
                reason: "status=\(statusStr) duration_ms=\(duration)"
            )
        } else {
            AppLogger.shared.log("stage=\(stage) status=\(statusStr) duration_ms=\(duration)")
        }
    }
}
