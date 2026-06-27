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
/// Live partials are produced by periodically re-inferring the accumulated
/// audio (every ~1.2s) — the model is resident so each partial is cheap.
final class WhisperEngine: ASREngine {

    private let settings = AppSettings.shared
    private var buffers: [AVAudioPCMBuffer] = []
    private let server = WhisperServerProcess.shared

    /// Partial-streaming state.
    private var partialTask: Task<Void, Never>?
    private var isInferring = false

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        buffers.append(buffer)
        // Kick off the partial-streaming loop on first buffer.
        if partialTask == nil {
            partialTask = Task { [weak self] in
                await self?.runPartials(onPartial: onPartial)
            }
        }
    }

    /// Periodically transcribe accumulated audio and emit partials.
    private func runPartials(onPartial: @escaping (String) -> Void) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s
            guard !Task.isCancelled, !buffers.isEmpty, !isInferring else { continue }
            isInferring = true
            let snap = buffers
            let text = await infer(buffers: snap)
            isInferring = false
            if !text.isEmpty { onPartial(text) }
        }
    }

    func finalize() async -> String {
        partialTask?.cancel()
        partialTask = nil
        guard !buffers.isEmpty else { return "" }
        let final = await infer(buffers: buffers)
        buffers.removeAll()
        return final
    }

    /// Transcribe the given buffers via the whisper-server /inference endpoint.
    private func infer(buffers: [AVAudioPCMBuffer]) async -> String {
        guard !buffers.isEmpty else { return "" }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("singar-\(UUID().uuidString).wav")
        do {
            try WAVWriter.write(buffers, to: tmp)
        } catch {
            NSLog("[SingAR] WAV write failed: \(error)")
            return ""
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return await transcribeViaServer(audio: tmp)
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

        // Punctuation: suppress via prompt when the user disabled auto-punctuation.
        if !settings.autoPunctuation {
            body.append("--\(boundary)\r\n".utf8Data)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n\r\n".utf8Data)
        }

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

/// Optional premium cloud steps. The app ships with NO embedded key — both
/// steps require a key (BYOK) or subscription token (proxy) in the Keychain.
///
/// Two independent steps, two providers:
///   - re-ASR    : transcribe the raw audio fresh with a top cloud model
///                 (OpenRouter /audio/transcriptions). Best for technical terms
///                 & code paths the local whisper mishears. Default model:
///                 gpt-4o-mini-transcribe (best code-path recognition, ~1s,
///                 ~$0.00012). gpt-4o-transcribe gives perfect slash-paths.
///   - LLM-polish: clean up the local transcript with qwen3-max (ZenMux
///                 chat completions, text-only). ~4s, ~$0.0001.
///
/// Each step resolves its own auth: BYOK key from Keychain, or subscription
/// token routed via the SingAR proxy (key lives server-side there).
final class CloudASR {

    private let settings = AppSettings.shared

    /// Proxy backend (SingAR). Keys live server-side, never in the app.
    private static let proxyBaseURL = URL(string: "https://api.singar.app/v1")!
    private static let openrouterURL = URL(string: "https://openrouter.ai/api/v1")!
    private static let zenmuxURL = URL(string: "https://zenmux.ai/api/v1")!

    // MARK: Availability

    /// re-ASR is available if an OpenRouter key OR a subscription token is set.
    var reASRAvailable: Bool {
        KeychainStore.get(KeychainStore.Account.openrouterKey) != nil
        || KeychainStore.get(KeychainStore.Account.subscriptionToken) != nil
    }

    /// LLM-polish is available if a ZenMux key OR a subscription token is set.
    var llmPolishAvailable: Bool {
        KeychainStore.get(KeychainStore.Account.zenmuxKey) != nil
        || KeychainStore.get(KeychainStore.Account.subscriptionToken) != nil
    }

    // MARK: Re-ASR (OpenRouter /audio/transcriptions)

    /// Transcribe raw audio bytes with the selected cloud model.
    func reASR(audio: Data, format: String = "wav") async -> String? {
        let b64 = audio.base64EncodedString()
        let payload: [String: Any] = [
            "model": settings.reASRModel.rawValue,
            "input_audio": ["data": b64, "format": format],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let (url, auth) = reASREndpoint()

        var req = URLRequest(url: url.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[SingAR] re-ASR HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            NSLog("[SingAR] re-ASR request failed: \(error)")
            return nil
        }
    }

    private func reASREndpoint() -> (URL, String) {
        // Subscription token → proxy (key server-side). Else BYOK OpenRouter key.
        if let token = KeychainStore.get(KeychainStore.Account.subscriptionToken) {
            return (Self.proxyBaseURL, token)
        }
        return (Self.openrouterURL, KeychainStore.get(KeychainStore.Account.openrouterKey) ?? "")
    }

    // MARK: LLM-polish (ZenMux chat completions)

    /// Clean up the local transcript for code / technical text.
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
            "messages": [["role": "user", "content": prompt]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let (url, auth) = llmPolishEndpoint()

        var req = URLRequest(url: url.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                NSLog("[SingAR] llmPolish HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
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
            NSLog("[SingAR] llmPolish request failed: \(error)")
            return nil
        }
    }

    private func llmPolishEndpoint() -> (URL, String) {
        if let token = KeychainStore.get(KeychainStore.Account.subscriptionToken) {
            return (Self.proxyBaseURL, token)
        }
        return (Self.zenmuxURL, KeychainStore.get(KeychainStore.Account.zenmuxKey) ?? "")
    }
}
