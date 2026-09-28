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

    /// Fired ONCE per speech segment when sustained silence is detected after
    /// speech (not repeatedly during a long pause — see `endOfSpeechFired`).
    /// Always invoked OUTSIDE the internal lock and on the CALLER's thread
    /// (the realtime tap thread in production) — callers must hop to main.
    var onEndOfSpeech: (() -> Void)?
    /// Fired on every audio buffer with the smoothed RMS level (0...1), for
    /// driving a live waveform/meter. Always delivered on the CALLER's thread
    /// (realtime tap in production) — callers must hop to main + throttle.
    /// Values are clamped to 0...1.
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

    /// Этап 2: tap-thread vs finalize race. `feed` runs on the realtime audio
    /// tap thread; `hasSpoken`/`isSpeaking`/`isFeeding` are read on main
    /// (stopDictation). All mutable state below is guarded by `lock`; public
    /// readers take the same lock. Callbacks fire OUTSIDE the lock.
    private let lock = NSLock()

    /// True while the user is (probably) speaking: loud buffer, or within the
    /// hangover window after one.
    private var _isSpeaking = false
    /// True once any speech has been seen since the last `reset()`.
    private var _hasSpoken = false
    /// Seconds of trailing silence still being fed to the recognizer after
    /// speech ended (grace tail). Read via `isFeeding`.
    private var _graceRemaining: TimeInterval = 0

    /// Thread-safe readers (same lock as `feed`).
    var isSpeaking: Bool { withLock { _isSpeaking } }
    var hasSpoken: Bool { withLock { _hasSpoken } }
    var graceRemaining: TimeInterval { withLock { _graceRemaining } }

    /// Should this buffer be passed to the recognizer? Speaking, or within the
    /// grace tail that lets SFSpeech finalise the trailing word.
    var isFeeding: Bool { withLock { _isSpeaking || _graceRemaining > 0 } }

    private var silenceAccumulator: TimeInterval = 0
    private var hangoverRemaining: TimeInterval = 0
    private var bufferCount = 0
    /// PCM frames seen since `reset()`. Diagnostic only — not an input to
    /// `hasSpoken` or the silence threshold.
    private var capturedFrameCount = 0
    /// PCM frames whose buffer RMS was at or above `silenceThreshold`.
    private var speechFrameCount = 0
    /// Этап 2: once-per-segment end-of-speech. Set on speech, consumed on the
    /// first silence-threshold crossing — a 5 s pause fires exactly once, not
    /// every 0.6 s. Cleared by speech or `reset()`.
    private var endOfSpeechFired = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Read-only diagnostic snapshot. The silence decision does not read these.
    var diagnosticCapturedFrames: Int { withLock { capturedFrameCount } }
    var diagnosticSpeechFrames: Int { withLock { speechFrameCount } }
    var diagnosticSilenceThreshold: Float { silenceThreshold }

    func reset() {
        withLock {
            _isSpeaking = false
            _hasSpoken = false
            silenceAccumulator = 0
            hangoverRemaining = 0
            _graceRemaining = 0
            bufferCount = 0
            capturedFrameCount = 0
            speechFrameCount = 0
            endOfSpeechFired = false
        }
    }

    /// Final (or checkpoint) line for the no_speech investigation.
    /// Does not change thresholds or whether the session counts as speech.
    func logSessionDiagnostic() {
        let frames: Int
        let speech: Int
        let threshold: Float
        (frames, speech, threshold) = withLock {
            (capturedFrameCount, speechFrameCount, silenceThreshold)
        }
        Self.emitDiagnostic(frames: frames, speech: speech, threshold: threshold)
    }

    private static func emitDiagnostic(frames: Int, speech: Int, threshold: Float) {
        AppLogger.shared.logPipeline(
            stage: "vad",
            code: "diagnostic",
            reason: "frames=\(frames) speech=\(speech) threshold=\(String(format: "%.3f", threshold))"
        )
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        // Copy the channel data synchronously: the caller may reuse the buffer
        // after `feed` returns (tap-thread reuse).
        let samples = Array(UnsafeBufferPointer(start: data, count: frames))
        let sampleRate = buffer.format.sampleRate
        let dt = Double(frames) / sampleRate

        // RMS energy over the buffer (no shared state touched).
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))

        // Drive the live level meter. Normalise against a comfortable speaking
        // level and clamp to 0...1 so the waveform has headroom but never clips.
        let level = min(max(rms / 0.08, 0), 1)

        // State transition under the lock; callbacks collected for delivery
        // OUTSIDE the lock (re-entrancy safe).
        var fireLevel = false
        var fireEndOfSpeech = false
        var logLine: String?
        var logDiagnostic = false
        var diagnosticFrames = 0
        var diagnosticSpeech = 0
        var diagnosticThreshold: Float = 0
        withLock {
            bufferCount += 1
            let count = bufferCount
            capturedFrameCount += frames
            if rms >= silenceThreshold {
                speechFrameCount += frames
            }
            if count == 1 || count % 20 == 0 {
                logDiagnostic = true
                diagnosticFrames = capturedFrameCount
                diagnosticSpeech = speechFrameCount
                diagnosticThreshold = silenceThreshold
            }
            let speakingBefore = _isSpeaking
            if rms >= silenceThreshold {
                _hasSpoken = true
                _isSpeaking = true
                silenceAccumulator = 0
                hangoverRemaining = hangoverSeconds
                _graceRemaining = 0   // speaking again — no trailing-silence tail needed
                endOfSpeechFired = false // new segment arms the one-shot again
            } else {
                // Count down the hangover; while it lasts we still treat the user
                // as speaking (short inter-word pauses).
                if hangoverRemaining > 0 {
                    hangoverRemaining -= dt
                    if hangoverRemaining <= 0 {
                        hangoverRemaining = 0
                        _isSpeaking = false
                        // Speech just ended → start the grace tail so the recognizer
                        // gets a beat of trailing silence to commit the final word.
                        if _hasSpoken { _graceRemaining = graceSeconds }
                    }
                } else {
                    _isSpeaking = false
                }
                // Run down the grace tail on every quiet buffer (independent of
                // hangover — it outlives it).
                if _graceRemaining > 0 {
                    _graceRemaining = max(0, _graceRemaining - dt)
                }

                if _hasSpoken {
                    silenceAccumulator += dt
                    if silenceAccumulator >= silenceDuration, !endOfSpeechFired {
                        endOfSpeechFired = true
                        fireEndOfSpeech = true
                        logLine = String(format: "[SingAR] VAD end-of-speech detected after %.2fs silence", silenceAccumulator)
                        silenceAccumulator = 0
                        // NOTE: `_hasSpoken` is intentionally NOT reset here. It means
                        // "speech occurred at some point this session" — used at
                        // finalize to decide whether to keep the transcript and run
                        // the cloud pass. Resetting it on a natural pause made the
                        // stop handler think the whole session was silent and wipe
                        // the live-typed text. Only `reset()` clears it.
                    }
                }
            }
            _ = speakingBefore
            _ = count
            fireLevel = true
            // Log every 20th buffer so we can see audio level without spamming.
            if count % 20 == 0 {
                logLine = logLine ?? String(format: "[SingAR] VAD buffer #%d rms=%.4f speaking=%@ spoken=%@ silence=%.2fs", count, rms, _isSpeaking ? "true" : "false", _hasSpoken ? "true" : "false", silenceAccumulator)
            }
        }

        if let logLine {
            NSLog("%@", logLine)
        }
        if logDiagnostic {
            Self.emitDiagnostic(frames: diagnosticFrames, speech: diagnosticSpeech, threshold: diagnosticThreshold)
        }
        // Callbacks outside the lock, on the caller's (tap) thread.
        if fireLevel {
            onLevel?(level)
        }
        if fireEndOfSpeech {
            onEndOfSpeech?()
        }
    }
}
