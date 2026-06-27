import AppKit
import AVFoundation

/// Orchestrates a single dictation cycle:
/// hotkey → audio capture + VAD → ASR (local, ±cloud) → text injection,
/// with media pause/resume around it and live status pushed to the menu bar.
final class DictationController {

    private let statusBar: StatusBarController
    private let settings = AppSettings.shared

    private let audio = AudioRecorder()
    private let vad = VoiceActivityDetector()
    private let injector = TextInjector()
    private let media = MediaController()
    private let commands = VoiceCommandParser()

    private var whisper: ASREngine = WhisperEngine()

    private var isDictating = false
    private var didPauseMedia = false

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        vad.onEndOfSpeech = { [weak self] in
            // End-of-speech fires on the audio thread; hop to main.
            DispatchQueue.main.async { self?.stopDictation() }
        }
    }

    // MARK: Public (called by HotkeyManager)

    func startDictation() {
        guard settings.enabled, !isDictating else { return }
        isDictating = true

        if settings.pauseMedia {
            didPauseMedia = media.pauseBackgroundMedia()
        }

        vad.reset()
        statusBar.setStatus(.listening)
        audio.start { [weak self] buffer in
            guard let self else { return }
            self.vad.feed(buffer)
            self.whisper.feed(buffer) { _ in /* partials: future C bridge */ }
        }
    }

    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        audio.stop()
        statusBar.setStatus(.recognizing)

        Task { [weak self] in
            guard let self else { return }
            let transcript = await self.whisper.finalize()
            await MainActor.run { self.finish(with: transcript) }
        }
    }

    func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        audio.stop()
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
    }

    // MARK: Pipeline

    private func finish(with text: String) {
        var output = text
        if settings.voiceCommands {
            output = commands.process(output)
        }
        // TODO(M4): if settings.cloudStep != .off, re-ASR or LLM-polish here.
        injector.insert(output)
        resumeMediaIfNeeded()
        statusBar.setStatus(.done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.statusBar.setStatus(.idle)
        }
    }

    private func resumeMediaIfNeeded() {
        if didPauseMedia {
            media.resumeBackgroundMedia()
            didPauseMedia = false
        }
    }
}
