import AVFoundation

/// Voice activity detection → end-of-speech + a live "is the user speaking
/// right now" flag used to GATE which audio reaches the recognizer. Energy-based
/// for now (cheap, no deps); pluggable for a Silero ONNX model later
/// without changing the interface.
///
/// The key outputs:
///   - `isSpeaking`: true on a loud buffer and for a short hangover afterwards,
///     so word boundaries aren't sliced. DictationController feeds only these
///     buffers (plus the grace tail) to SFSpeech — silence never reaches the
///     recognizer, which is what stops its "thank you" hallucinations.
///   - `isFeeding`: `isSpeaking` OR within the grace tail after speech ends.
///     SFSpeech needs a beat of trailing silence after the last word to commit
///     it as a partial; without grace, the last word stayed un-finalised until
///     the next dictation (the "chops the end off" bug). Grace only starts after
///     real speech, so a fully-silent session is never fed.
///   - `hasSpoken`: true once any speech has been seen this session. Used at
///     finalize to discard a fully-silent session instead of printing phantoms.
final class VoiceActivityDetector {

    /// Fired once when sustained silence is detected after speech.
    var onEndOfSpeech: (() -> Void)?
    /// Fired on every audio buffer with the smoothed RMS level (0...1), for
    /// driving a live waveform/meter. Always delivered on the audio thread.
    var onLevel: ((Float) -> Void)?

    /// RMS amplitude below this counts as silence.
    private let silenceThreshold: Float = 0.012
    /// Continuous silence required (seconds) to declare end-of-speech.
    private let silenceDuration: TimeInterval = 0.6
    /// How long to keep `isSpeaking` true after the last loud buffer, so we
    /// don't slice word boundaries when speech dips briefly quiet.
    private let hangoverSeconds: TimeInterval = 0.3
    /// Trailing-silence tail fed to the recognizer AFTER speech ends, so SFSpeech
    /// gets the "no more audio coming" cue it needs to commit the final word as
    /// a partial — instead of holding it back until the user speaks again.
    private let graceSeconds: TimeInterval = 0.7

    /// True while the user is (probably) speaking: loud buffer, or within the
    /// hangover window after one.
    private(set) var isSpeaking = false
    /// True once any speech has been seen since the last `reset()`.
    private(set) var hasSpoken = false
    /// Seconds of trailing silence still being fed to the recognizer after
    /// speech ended (grace tail). Read via `isFeeding`.
    private(set) var graceRemaining: TimeInterval = 0

    /// Should this buffer be passed to the recognizer? Speaking, or within the
    /// grace tail that lets SFSpeech finalise the trailing word.
    var isFeeding: Bool { isSpeaking || graceRemaining > 0 }

    private var silenceAccumulator: TimeInterval = 0
    private var hangoverRemaining: TimeInterval = 0
    private var bufferCount = 0

    func reset() {
        isSpeaking = false
        hasSpoken = false
        silenceAccumulator = 0
        hangoverRemaining = 0
        graceRemaining = 0
        bufferCount = 0
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        bufferCount += 1
        let dt = Double(frames) / buffer.format.sampleRate

        // RMS energy over the buffer.
        var sum: Float = 0
        for i in 0..<frames {
            let s = data[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))

        // Drive the live level meter. Normalise against a comfortable speaking
        // level and clamp to 0...1 so the waveform has headroom but never clips.
        let level = min(rms / 0.08, 1)
        onLevel?(level)

        // Log every 20th buffer so we can see audio level without spamming.
        if bufferCount % 20 == 0 {
            NSLog("[SingAR] VAD buffer #\(bufferCount) rms=\(String(format: "%.4f", rms)) speaking=\(isSpeaking) spoken=\(hasSpoken) silence=\(String(format: "%.2f", silenceAccumulator))s")
        }

        if rms >= silenceThreshold {
            hasSpoken = true
            isSpeaking = true
            silenceAccumulator = 0
            hangoverRemaining = hangoverSeconds
            graceRemaining = 0   // speaking again — no trailing-silence tail needed
        } else {
            // Count down the hangover; while it lasts we still treat the user
            // as speaking (short inter-word pauses).
            if hangoverRemaining > 0 {
                hangoverRemaining -= dt
                if hangoverRemaining <= 0 {
                    hangoverRemaining = 0
                    isSpeaking = false
                    // Speech just ended → start the grace tail so the recognizer
                    // gets a beat of trailing silence to commit the final word.
                    if hasSpoken { graceRemaining = graceSeconds }
                }
            } else {
                isSpeaking = false
            }
            // Run down the grace tail on every quiet buffer (independent of
            // hangover — it outlives it).
            if graceRemaining > 0 {
                graceRemaining = max(0, graceRemaining - dt)
            }

            if hasSpoken {
                silenceAccumulator += dt
                if silenceAccumulator >= silenceDuration {
                    NSLog("[SingAR] VAD end-of-speech detected after \(String(format: "%.2f", silenceAccumulator))s silence")
                    onEndOfSpeech?()
                    silenceAccumulator = 0
                    // NOTE: `hasSpoken` is intentionally NOT reset here. It means
                    // "speech occurred at some point this session" — used at
                    // finalize to decide whether to keep the transcript and run
                    // the cloud pass. Resetting it on a natural pause made the
                    // stop handler think the whole session was silent and wipe
                    // the live-typed text. Only `reset()` clears it.
                }
            }
        }
    }
}
