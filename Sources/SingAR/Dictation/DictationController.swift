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
    private let cloud = CloudASR()
    private let overlay = DictationOverlay()

    private var isDictating = false
    private var didPauseMedia = false
    /// Raw audio captured this session, kept for a possible cloud re-ASR pass.
    private var capturedAudioData: Data?

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

        // Show the overlay anchored under the status item.
        if let button = statusBar.statusItemButtonFrame {
            overlay.show(near: button.origin)
        }

        audio.start { [weak self] buffer in
            guard let self else { return }
            self.vad.feed(buffer)
            self.overlay.pulse()
            if self.settings.livePartials {
                self.whisper.feed(buffer) { partial in
                    self.overlay.setTranscript(partial)
                }
            } else {
                self.whisper.feed(buffer) { _ in }
            }
        }
    }

    func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        audio.stop()
        overlay.hide()
        statusBar.setStatus(.recognizing)

        // Stash captured audio for a possible cloud re-ASR pass.
        if settings.cloudStep == .reASR, cloud.reASRAvailable {
            capturedAudioData = flattenAudio()
        }

        Task { [weak self] in
            guard let self else { return }
            var transcript = await self.whisper.finalize()

            // Optional premium cloud step. Only when configured.
            if self.settings.cloudStep != .off {
                if self.settings.cloudStep == .reASR, self.cloud.reASRAvailable,
                   let audio = self.capturedAudioData {
                    await MainActor.run { self.statusBar.setStatus(.cloud) }
                    if let cloudText = await self.cloud.reASR(audio: audio), !cloudText.isEmpty {
                        transcript = cloudText
                    }
                } else if self.settings.cloudStep == .llmPolish, self.cloud.llmPolishAvailable,
                          !transcript.isEmpty {
                    await MainActor.run { self.statusBar.setStatus(.cloud) }
                    if let polished = await self.cloud.llmPolish(text: transcript), !polished.isEmpty {
                        transcript = polished
                    }
                }
                self.capturedAudioData = nil
            }

            let finalText = transcript
            await MainActor.run { self.finish(with: finalText) }
        }
    }

    func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        audio.stop()
        overlay.hide()
        capturedAudioData = nil
        resumeMediaIfNeeded()
        statusBar.setStatus(.idle)
    }

    // MARK: Pipeline

    private func finish(with text: String) {
        var output = text
        if settings.voiceCommands {
            output = commands.process(output)
        }
        injector.insert(output)
        resumeMediaIfNeeded()
        statusBar.setStatus(.done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.statusBar.setStatus(.idle)
        }
    }

    /// Concatenate captured PCM buffers into a single WAV blob for cloud re-ASR.
    private func flattenAudio() -> Data? {
        let buffers = audio.capturedBuffers
        guard !buffers.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-cloud-\(UUID().uuidString).wav")
        do {
            try WAVWriter.write(buffers, to: tmp)
            let data = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            return data
        } catch {
            NSLog("[SingAR] flattenAudio failed: \(error)")
            return nil
        }
    }

    private func resumeMediaIfNeeded() {
        if didPauseMedia {
            media.resumeBackgroundMedia()
            didPauseMedia = false
        }
    }
}
