import AVFoundation

/// Voice activity detection → end-of-speech. Energy-based for now (cheap, no
/// extra deps); ~600 ms of silence below threshold ends a phrase. Pluggable for
/// a Silero ONNX model later without changing the interface.
final class VoiceActivityDetector {

    /// Fired once when sustained silence is detected after speech.
    var onEndOfSpeech: (() -> Void)?

    /// RMS amplitude below this counts as silence.
    private let silenceThreshold: Float = 0.012
    /// Continuous silence required (seconds) to declare end-of-speech.
    private let silenceDuration: TimeInterval = 0.6

    private var hasSpoken = false
    private var silenceAccumulator: TimeInterval = 0

    func reset() {
        hasSpoken = false
        silenceAccumulator = 0
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        // RMS energy over the buffer.
        var sum: Float = 0
        for i in 0..<frames {
            let s = data[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))

        if rms >= silenceThreshold {
            hasSpoken = true
            silenceAccumulator = 0
        } else if hasSpoken {
            silenceAccumulator += Double(frames) / buffer.format.sampleRate
            if silenceAccumulator >= silenceDuration {
                onEndOfSpeech?()
                hasSpoken = false
                silenceAccumulator = 0
            }
        }
    }
}
