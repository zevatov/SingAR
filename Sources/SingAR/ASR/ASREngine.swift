import AVFoundation

/// Pluggable speech-to-text backend. The local engine is on the hot path
/// (instant partials); cloud is an optional follow-up step.
protocol ASREngine {
    /// Stream a chunk; `onPartial` fires with incremental text for live display.
    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void)
    /// Finalize and return the complete transcript for the captured session.
    func finalize() async -> String
}

/// whisper.cpp + CoreML/Metal, large-v3-turbo (default) or large-v3.
///
/// TODO(M1): bridge to whisper.cpp via the C API (System C module or prebuilt
/// .xcframework). Emit partials per segment; return concatenated final text.
final class WhisperEngine: ASREngine {
    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        // TODO(M1)
    }
    func finalize() async -> String {
        // TODO(M1)
        return ""
    }
}

/// Optional cloud re-ASR / LLM-polish through ZenMux.
/// `qwen3-asr-flash`: OpenAI-compatible chat completions with `input_audio`
/// (base64) → transcript in message.content.
///
/// TODO(M4): implement `reASR(audio:)` and `llmPolish(text:)`.
final class ZenMuxASR {
    func reASR(audio: Data) async -> String? { return nil }
    func llmPolish(text: String) async -> String? { return nil }
}
