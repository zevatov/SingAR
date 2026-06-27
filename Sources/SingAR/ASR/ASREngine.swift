import AVFoundation
import Foundation

/// Pluggable speech-to-text backend. The local engine is on the hot path
/// (instant partials); cloud is an optional follow-up step.
protocol ASREngine {
    /// Stream a chunk; `onPartial` fires with incremental text for live display.
    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void)
    /// Finalize and return the complete transcript for the captured session.
    func finalize() async -> String
}

/// Local ASR via a long-lived `whisper-server` (HTTP `/inference`). The model
/// stays resident in memory, so each dictation is ~1.7s with no cold start.
final class WhisperEngine: ASREngine {

    private let settings = AppSettings.shared
    private var buffers: [AVAudioPCMBuffer] = []
    private let server = WhisperServerProcess.shared

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        // HTTP mode: accumulate buffers; partials require the streaming endpoint
        // (whisper-stream) — TODO for live partials.
        buffers.append(buffer)
    }

    func finalize() async -> String {
        guard !buffers.isEmpty else { return "" }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-\(UUID().uuidString).wav")
        do {
            try WAVWriter.write(buffers, to: tmp)
        } catch {
            NSLog("[SingAR] WAV write failed: \(error)")
            buffers.removeAll()
            return ""
        }

        let result = await transcribeViaServer(audio: tmp)
        buffers.removeAll()
        try? FileManager.default.removeItem(at: tmp)
        return result
    }

    private func transcribeViaServer(audio: URL) async -> String {
        let endpoint = server.baseURL.appendingPathComponent("inference")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let boundary = "----SingAR\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // file field
        let filename = audio.lastPathComponent
        let fileData = (try? Data(contentsOf: audio)) ?? Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8Data)
        body.append("Content-Type: audio/wav\r\n\r\n".utf8Data)
        body.append(fileData)
        body.append("\r\n".utf8Data)

        // temperature
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n0.0\r\n".utf8Data)

        // response_format
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".utf8Data)

        // language
        let lang = settings.language == .auto ? "auto" : settings.language.rawValue
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(lang)\r\n".utf8Data)

        body.append("--\(boundary)--\r\n".utf8Data)
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[SingAR] whisper-server HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return ""
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            NSLog("[SingAR] whisper-server request failed: \(error)")
            return ""
        }
    }
}

private extension String {
    var utf8Data: Data { data(using: .utf8) ?? Data() }
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
