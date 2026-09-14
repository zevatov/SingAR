import AppKit
import AVFoundation

// MARK: - Этап 3: FinalizePipeline
//
// stop→snapshot→ASR/polish→commit→history→HUD. Код перенесён из
// `DictationController.swift` 1:1: immutable snapshot аудио, generation-гварды,
// cancelGate-фазы, typed cloud outcomes, историю пишем только после
// подтверждённой вставки — поведение Этапа 2 не изменено.
extension DictationController {

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
        SoundFeedback.stop()
        resumeMediaIfNeeded()

        // Silence / Noise Hallucination Gate:
        // If no human speech was detected during the recording session (vad.hasSpoken == false),
        // abort immediately. Skip cloud/local ASR entirely and do not insert garbage.
        if !vad.hasSpoken {
            AppLogger.shared.log("🔇 stopDictation: no speech detected (vad.hasSpoken == false) — skipping ASR and injection")
            audio.stop()
            localAsr.cancel()
            geminiAsr?.cancel()
            if hasLiveTyped && !lastLiveText.isEmpty {
                let range = NSRange(location: 0, length: (lastLiveText as NSString).length)
                if !focusTargetGate.replaceText(generation: gen, range: range, with: "") {
                    injector.backspace(count: range.length)
                }
                lastLiveText = ""
                hasLiveTyped = false
            }
            statusBar.setStatus(.failed)
            indicator.setStatus(.failed, message: "Речь не обнаружена")
            cancelGate.finalizeFinished(gen: gen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.sessionGeneration == gen else { return }
                self.indicator.hide()
                self.statusBar.setStatus(.idle)
            }
            return
        }

        logStage("transcribing", startedAt: transcribingStartedAt)

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
                    // Этап 2: 100мс активация БЕЗ блокировки main — фоновая
                    // задержка + асинхронный ре-ентри (тот же gen-guard).
                    if !self.settings.stopOnFocusLoss, let targetPID = self.focusTargetGate.capturedPID {
                        if let targetApp = NSRunningApplication(processIdentifier: targetPID), !targetApp.isActive {
                            AppLogger.shared.log("🪟 focus guard disabled: re-activating original target app (PID=\(targetPID))")
                            targetApp.activate()
                            let genCopy = gen
                            Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                await MainActor.run { [weak self] in
                                    guard let self, self.sessionGeneration == genCopy, !Task.isCancelled else { return }
                                    self.continueFinalizeAfterActivation(
                                        gen: genCopy,
                                        textToCommit: textToCommit,
                                        recordedProvider: recordedProvider,
                                        recordedModel: recordedModel,
                                        truncationWarning: truncationWarning,
                                        finalCloudError: finalCloudError,
                                        finalPolishError: finalPolishError
                                    )
                                }
                            }
                            return
                        }
                    }
                    self.continueFinalizeAfterActivation(
                        gen: gen,
                        textToCommit: textToCommit,
                        recordedProvider: recordedProvider,
                        recordedModel: recordedModel,
                        truncationWarning: truncationWarning,
                        finalCloudError: finalCloudError,
                        finalPolishError: finalPolishError
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == gen else { return }
                self.finalizeTask = finalize
            }
        }
    }

    /// Этап 2: продолжение финализации после (опциональной) фоновой паузы
    /// активации. Выделено из `stopDictation`, чтобы убрать `usleep(100мс)`
    /// с main: поведение идентично (тот же gen-guard, те же ветки).
    /// Вызывается ТОЛЬКО внутри `MainActor.run` (контроллер `@MainActor`).
    private func continueFinalizeAfterActivation(
        gen: Int,
        textToCommit: String,
        recordedProvider: String,
        recordedModel: String,
        truncationWarning: Bool,
        finalCloudError: CloudASRError?,
        finalPolishError: CloudASRError?
    ) {
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
