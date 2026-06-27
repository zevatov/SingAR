import AppKit
import AVFoundation

/// Orchestrates a single dictation cycle:
/// hotkey → audio capture + VAD → ASR (local, ±cloud) → text injection,
/// with media pause/resume around it and live status pushed to the menu bar.
///
/// Wiring is scaffolded; subsystems are stubbed with their final interfaces so
/// each milestone plugs in without reshaping this controller.
final class DictationController {

    private let statusBar: StatusBarController
    private let settings = AppSettings.shared

    private let audio = AudioRecorder()
    private let vad = VoiceActivityDetector()
    private let injector = TextInjector()
    private let media = MediaController()
    private let commands = VoiceCommandParser()

    private var whisper: ASREngine = WhisperEngine()
    private var cloud: ZenMuxASR?

    private var isDictating = false
    private var didPauseMedia = false
    private var partialTranscript: String = ""

    init(statusBar: StatusBarController) {
        self.statusBar = statusBar
        // TODO(M4): instantiate `cloud` when a ZenMux key is present in Keychain.
    }

    // MARK: Public (called by HotkeyManager)

    func startDictation() {
        guard settings.enabled, !isDictating else { return }
        isDictating = true
        partialTranscript = ""

        if settings.pauseMedia {
            didPauseMedia = media.pauseBackgroundMedia()
        }

        statusBar.setStatus(.listening)
        // TODO(M1): audio.start { [weak self] buffer in self?.handle(buffer) }
    }

    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        statusBar.setStatus(.recognizing)

        // TODO(M1): audio.stop() then run ASR on captured PCM.
        let final = partialTranscript   // placeholder until ASR is wired
        finish(with: final)
    }

    func cancelDictation() {
        isDictating = false
        partialTranscript = ""
        // TODO(M1): audio.stop()
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
    }

    // MARK: Pipeline

    private func handle(_ buffer: AVAudioPCMBuffer) {
        // TODO(M1): feed VAD; on end-of-speech call stopDictation().
        // TODO(M1): stream chunks to WhisperEngine for partial transcripts.
    }

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
