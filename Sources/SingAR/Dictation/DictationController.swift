import AppKit
import AVFoundation

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
    private var didPauseMedia = false
    private var recordingStartedAt = Date()

    // Live typing state
    private var lastLiveText = ""
    private var hasLiveTyped = false

    private var focusCheckTimer: Timer?
    private var sessionGeneration = 0

    var onFocusLost: (() -> Void)?

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
    }

    // MARK: Public (called by HotkeyManager)

    func startDictation() {
        guard settings.enabled, !isDictating else {
            NSLog("[SingAR] startDictation skipped: enabled=\(settings.enabled) isDictating=\(isDictating)")
            return
        }

        guard textEditorFocused() else {
            NSLog("[SingAR] no text field focused — not starting dictation")
            statusBar.flashStatus()
            return
        }

        isDictating = true
        sessionGeneration &+= 1
        recordingStartedAt = Date()
        lastLiveText = ""
        hasLiveTyped = false
        logStage("recording", startedAt: recordingStartedAt)

        // Smart Media Pause (immediately pause, track if playback was active)
        if settings.pauseMedia {
            media.isMediaPlaying { [weak self] isPlaying in
                if isPlaying {
                    self?.didPauseMedia = true
                }
            }
            media.pauseBackgroundMedia()
        }

        vad.reset()
        statusBar.setStatus(.listening)
        indicator.setStatus(.listening)
        startFocusMonitoring()

        if let frame = statusBar.statusItemButtonFrame {
            indicator.show(near: NSPoint(x: frame.midX, y: frame.maxY))
        }
        vad.onLevel = { [weak self] level in
            self?.indicator.setLevel(level)
        }

        // Initialize engines
        localAsr = SpeechEngine()
        if cloud.available {
            geminiAsr = GeminiLiveEngine()
        } else {
            geminiAsr = nil
        }

        SoundFeedback.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isDictating else { return }
            self.audio.start { [weak self] buffer in
                guard let self, self.isDictating else { return }
                self.vad.feed(buffer)

                // Feed real-time speech engine with live typing callback (mutually exclusive)
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

    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        stopFocusMonitoring()

        let gen = sessionGeneration
        let transcribingStartedAt = Date()
        logStage("recording", startedAt: recordingStartedAt, completed: true)
        logStage("transcribing", startedAt: transcribingStartedAt)

        let captured = audio.capturedBuffers
        audio.stop()
        SoundFeedback.stop()
        indicator.hide()
        statusBar.setStatus(.idle)
        resumeMediaIfNeeded()

        Task { [weak self] in
            guard let self else { return }
            var provider = "live"
            var model = self.settings.cloudModel.rawValue

            // 1. Gather live text from engines
            async let localFinal = self.localAsr.finalize()
            async let geminiFinal = self.geminiAsr?.finalize() ?? ""

            let l = await localFinal
            let g = await geminiFinal

            var transcript = !g.isEmpty ? g : l
            if transcript.isEmpty {
                transcript = self.lastLiveText
            }

            var finalText = self.processed(transcript)
            NSLog("[SingAR] 📝 stopDictation: liveText=\"%@\" cloudCleanup=%d available=%d capturedBuffers=%d", String(finalText.prefix(60)), self.settings.cloudCleanup ? 1 : 0, self.cloud.available ? 1 : 0, captured.count)

            // 2. High-precision ASR & Vibe-Coder Polish
            if self.settings.cloudCleanup && self.cloud.available {
                if let audioData = WAVWriter.wavData(from: captured) {
                    NSLog("[SingAR] 🎧 stopDictation: WAV generated OK, size=%d bytes", audioData.count)
                    if let transcribed = await self.cloud.cloudTranscribe(audio: audioData), !transcribed.isEmpty {
                        NSLog("[SingAR] ✅ stopDictation: transcribed=\"%@\"", String(transcribed.prefix(80)))

                        // 3. Vibe-Coder formatting pass (flags, paths, camelCase, .env)
                        if let polished = await self.cloud.polish(text: transcribed), !polished.isEmpty {
                            finalText = self.processed(polished)
                            provider = self.settings.cloudModel.rawValue + "+polish"
                        } else {
                            finalText = self.processed(transcribed)
                            provider = self.settings.cloudModel.rawValue
                        }
                        model = self.settings.cloudModel.rawValue
                    } else {
                        NSLog("[SingAR] ⚠️ stopDictation: cloudTranscribe returned nil, keeping liveText")
                    }
                } else {
                    NSLog("[SingAR] ❌ stopDictation: WAVWriter.wavData returned nil from %d buffers", captured.count)
                }
            }

            let textToCommit = finalText
            let recordedProvider = provider
            let recordedModel = model

            await MainActor.run {
                guard self.sessionGeneration == gen else { return }
                self.logStage("transcribing", startedAt: transcribingStartedAt, completed: true)

                if self.hasLiveTyped {
                    // Smoothly apply the final polished audio text to the screen
                    self.applyPolishedText(textToCommit)
                } else if !textToCommit.isEmpty {
                    self.injector.insert(textToCommit)
                }

                if !textToCommit.isEmpty {
                    let latencyMs = Int(Date().timeIntervalSince(self.recordingStartedAt) * 1_000)
                    self.history.append(DictationHistoryEntry(
                        timestamp: Date(),
                        provider: recordedProvider,
                        model: recordedModel,
                        latencyMs: latencyMs,
                        text: textToCommit
                    ))
                }
            }
        }
    }

    func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        stopFocusMonitoring()
        audio.stop()
        SoundFeedback.stop()
        indicator.hide()

        // Erase any live typed text
        if hasLiveTyped && !lastLiveText.isEmpty {
            injector.backspace(count: lastLiveText.count)
        }
        lastLiveText = ""
        hasLiveTyped = false

        localAsr.cancel()
        geminiAsr?.cancel()
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
    }

    // MARK: Real-time Live Typing Engine

    private func handleLivePartial(_ newText: String) {
        guard isDictating else { return }
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

        if backspacesNeeded > 0 {
            injector.backspace(count: backspacesNeeded)
        }
        if !charsToType.isEmpty {
            injector.typeText(charsToType)
        }

        lastLiveText = cleaned
        hasLiveTyped = true
    }

    /// Guaranteed application of polished text upon dictation finish
    private func applyPolishedText(_ polished: String) {
        guard !polished.isEmpty, polished != lastLiveText else { return }

        let oldChars = Array(lastLiveText)
        let newChars = Array(polished)

        var commonPrefixLength = 0
        while commonPrefixLength < oldChars.count &&
              commonPrefixLength < newChars.count &&
              oldChars[commonPrefixLength] == newChars[commonPrefixLength] {
            commonPrefixLength += 1
        }

        let backspacesNeeded = oldChars.count - commonPrefixLength
        let charsToType = String(newChars[commonPrefixLength...])

        if backspacesNeeded > 0 {
            injector.backspace(count: backspacesNeeded)
        }
        if !charsToType.isEmpty {
            injector.typeText(charsToType)
        }

        lastLiveText = polished
    }

    // MARK: Focus Monitoring

    private func startFocusMonitoring() {
        focusCheckTimer?.invalidate()
        focusCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isDictating else { return }
            if !self.textEditorFocused() {
                NSLog("[SingAR] focused element lost / not a text field — stopping dictation")
                self.onFocusLost?()
                self.stopDictation()
            }
        }
    }

    private func stopFocusMonitoring() {
        focusCheckTimer?.invalidate()
        focusCheckTimer = nil
    }

    private func textEditorFocused() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return true }
        return frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
    }

    // MARK: Post-processing

    private func processed(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if settings.voiceCommands {
            return commands.process(raw)
        }
        return raw
    }

    private func resumeMediaIfNeeded() {
        if didPauseMedia {
            media.resumeBackgroundMedia()
            didPauseMedia = false
        }
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
