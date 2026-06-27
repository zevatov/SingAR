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

/// Optional cloud step for premium users: re-ASR (`qwen3-asr-flash`) or
/// LLM-polish (`qwen3-max`) over the local transcript, for top quality on
/// technical terms / code.
///
/// Two operation modes — the app ships with NO embedded key:
///   - .byok:   user's own ZenMux key from Keychain → direct call to ZenMux.
///   - .proxy:  subscription token from Keychain → request to the SingAR proxy,
///              which holds the ZenMux key server-side. Billing/quota handled
///              there. This is the monetisation path: local ASR free for all,
///              cloud step behind a subscription.
///
/// `mode` is resolved from what's present in Keychain: a subscription token
/// wins (proxy), otherwise a ZenMux key is used (BYOK), otherwise the cloud
/// step is unavailable.
final class ZenMuxASR {

    enum CloudMode {
        case byok       // user's ZenMux key, direct
        case proxy      // subscription token, via SingAR backend
    }

    /// The proxy backend. The ZenMux key lives only here, never in the app.
    private static let proxyBaseURL = URL(string: "https://api.singar.app/v1")!
    private static let zenmuxBaseURL = URL(string: "https://zenmux.ai/api/v1")!

    private var mode: CloudMode? {
        if KeychainStore.get(KeychainStore.Account.subscriptionToken) != nil { return .proxy }
        if KeychainStore.get(KeychainStore.Account.zenmuxKey) != nil { return .byok }
        return nil
    }

    /// True if a cloud step is configured (key or subscription present).
    var isAvailable: Bool { mode != nil }

    // MARK: Re-ASR

    /// Send raw audio, get a fresh transcript from qwen3-asr-flash.
    func reASR(audio: Data, format: String = "wav") async -> String? {
        let audioB64 = audio.base64EncodedString()
        let payload: [String: Any] = [
            "model": "qwen/qwen3-asr-flash",
            "messages": [
                ["role": "user", "content": [
                    ["type": "text", "text": "Transcribe this audio verbatim."],
                    ["type": "input_audio",
                     "input_audio": ["data": audioB64, "format": format]],
                ]]
            ]
        ]
        return await post(payload: payload)
    }

    // MARK: LLM polish

    /// Take the local transcript and have qwen3-max clean it up for code /
    /// technical text (punctuation, identifiers, file paths).
    func llmPolish(text: String) async -> String? {
        let prompt = """
        You are a dictation post-processor for coding and technical text. Fix \
        punctuation, spacing, and obvious mis-transcriptions of technical terms \
        (file paths, command names, identifiers). Output ONLY the corrected \
        text, nothing else.

        Transcript:
        \(text)
        """
        let payload: [String: Any] = [
            "model": "qwen/qwen3-max",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        return await post(payload: payload)
    }

    // MARK: Shared request path

    private func post(payload: [String: Any]) async -> String? {
        guard let mode else { return nil }
        let (url, auth) = endpoint(for: mode)
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: url.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[SingAR] cloud step HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let content = choices.first?["message"] as? [String: Any],
               let text = content["content"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            NSLog("[SingAR] cloud step request failed: \(error)")
            return nil
        }
    }

    /// Resolve endpoint + auth header value per mode.
    private func endpoint(for mode: CloudMode) -> (URL, String) {
        switch mode {
        case .byok:
            return (Self.zenmuxBaseURL, KeychainStore.get(KeychainStore.Account.zenmuxKey) ?? "")
        case .proxy:
            // The proxy accepts the subscription token; it injects the ZenMux
            // key server-side and forwards the request.
            return (Self.proxyBaseURL, KeychainStore.get(KeychainStore.Account.subscriptionToken) ?? "")
        }
    }
}
