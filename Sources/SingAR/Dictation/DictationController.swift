import AppKit
import AVFoundation

/// Orchestrates real-time live typing dictation:
/// hotkey → live microphone capture → real-time keystroke typing into active app → instant finish.
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

        if settings.pauseMedia {
            didPauseMedia = media.pauseBackgroundMedia()
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
        if settings.cloudModel == .gemini35Transcribe && cloud.available {
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

                // Feed real-time speech engine with live typing callback
                self.localAsr.feed(buffer) { [weak self] partial in
                    guard let self, self.isDictating else { return }
                    DispatchQueue.main.async {
                        self.handleLivePartial(partial)
                    }
                }

                self.geminiAsr?.feed(buffer) { [weak self] partial in
                    guard let self, self.isDictating else { return }
                    DispatchQueue.main.async {
                        if !partial.isEmpty {
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

        statusBar.setStatus(.recognizing)
        indicator.setStatus(.recognizing)

        Task { [weak self] in
            guard let self else { return }
            var provider = "gemini-live"
            var model = "gemini-3.5-transcribe-live"

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

            // 2. Optional AI Post-Processing / Polish with Gemini
            if self.settings.cloudCleanup && self.cloud.available,
               let audioData = self.flattenAudio() {
                if let polished = await self.cloud.cloudTranscribe(audio: audioData), !polished.isEmpty {
                    finalText = self.processed(polished)
                    provider = "gemini-live+polish"
                    model = "gemini-3.5-transcribe"
                }
            }

            await MainActor.run {
                guard self.sessionGeneration == gen else { return }
                self.logStage("transcribing", startedAt: transcribingStartedAt, completed: true)

                if self.hasLiveTyped {
                    // Smoothly update the live-typed text on screen with the polished text
                    self.handleLivePartial(finalText)
                } else if !finalText.isEmpty {
                    // If live typing was bypassed, insert final text directly
                    self.statusBar.setStatus(.inserting)
                    self.indicator.setStatus(.inserting)
                    self.injector.insert(finalText)
                }

                if !finalText.isEmpty {
                    let latencyMs = Int(Date().timeIntervalSince(self.recordingStartedAt) * 1_000)
                    self.history.append(DictationHistoryEntry(
                        timestamp: Date(),
                        provider: provider,
                        model: model,
                        latencyMs: latencyMs,
                        text: finalText
                    ))
                }

                self.finish()
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
        guard isDictating || !hasLiveTyped else { return }
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

    private func flattenAudio() -> Data? {
        let buffers = audio.capturedBuffers
        guard !buffers.isEmpty else { return nil }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-session-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try WAVWriter.write(buffers, to: tmpURL)
            return try Data(contentsOf: tmpURL)
        } catch {
            NSLog("[SingAR] flattenAudio failed: \(error)")
            return nil
        }
    }

    private func finish() {
        audio.stop()
        SoundFeedback.stop()
        indicator.hide()
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
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
