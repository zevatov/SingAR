import AVFoundation

/// Captures microphone audio via AVAudioEngine and delivers PCM buffers to a
/// callback. 16 kHz mono Float32 is the target format for the ASR pipeline.
///
/// TODO(M1): AVAudioEngine + input tap, install tap on inputNode, resample to
/// 16k/mono, hand buffers to the callback. Respect AVAudioSession permissions.
final class AudioRecorder {

    private let engine = AVAudioEngine()
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        // TODO(M1): request permission, configure engine, install tap, start.
    }

    func stop() {
        // TODO(M1): stop engine, remove tap.
        onBuffer = nil
    }
}

/// Voice activity detection → end-of-speech. ~500–700 ms of silence ends a
/// phrase and triggers stopDictation().
///
/// TODO(M1): Silero VAD via ONNX Runtime, or whisper.cpp built-in VAD.
final class VoiceActivityDetector {

    var onEndOfSpeech: (() -> Void)?

    func feed(_ buffer: AVAudioPCMBuffer) {
        // TODO(M1): run VAD, track silence duration, fire onEndOfSpeech.
    }
}
