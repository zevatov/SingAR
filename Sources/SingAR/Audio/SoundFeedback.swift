import AppKit

/// Short Apple-dictation-style sound cues for the start and stop of a dictation
/// session. Apple's own dictation chime lives in a private subsystem with no
/// public API, so we use the closest standard system sounds: `Tink` on start
/// (a soft high blip) and `Glass` on stop (a resolving chime). Both are
/// `NSSound(named:)`, played asynchronously.
///
/// Start is played ~0.2s before mic capture begins (DictationController delays
/// `audio.start`), because there is no acoustic echo cancellation — playing it
/// while the tap is active would let the chime bleed into the recording. Stop
/// is safe: it plays after `audio.stop()`, so the tap is already gone.
enum SoundFeedback {

    /// Play on dictation start.
    static func start() {
        NSSound(named: "Tink")?.play()
    }

    /// Play on dictation stop / cancel.
    static func stop() {
        NSSound(named: "Glass")?.play()
    }
}
