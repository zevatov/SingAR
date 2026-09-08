import AVFoundation
import Foundation

/// Real-time bidirectional streaming ASR engine backed by Google Gemini 3.5 Transcribe Live (WebSocket).
/// Streams live microphone PCM audio directly to Google and receives instantaneous live transcription.
final class GeminiLiveEngine: ASREngine {

    private let settings = AppSettings.shared
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession

    private var onPartial: ((String) -> Void)?
    private var accumulatedText = ""
    private var isConnected = false
    private var isAlive = false
    private let lock = NSLock()

    // Bounded pre-connect buffer: chunks arriving before `setupComplete` are
    // held here; the cap (~10 s of 16 kHz mono PCM16 = 320 KB) keeps worst-case
    // memory small even if the socket never completes setup.
    // Overflow policy: DROP-OLDEST (not fail-fast). `feed` runs on the realtime
    // audio-tap thread — blocking/skip-live there degrades live dictation; the
    // oldest pre-connect audio is least valuable (speech start), so dropping it
    // minimizes transcript loss. No WebSocket message format is affected.
    private static let maxPendingChunks = 200
    private var pendingAudioQueue: [Data] = []
    private var pendingDroppedCount = 0
    private var setupCompleteReceived = false
    private var completionContinuation: CheckedContinuation<String, Never>?

    // Gate 2.4: last typed failure on the live path (setup/WS/HTTP status).
    // `finalize()` still returns `String` per the ASREngine protocol, so the
    // DictationController fallback contract (error → live text) is unchanged;
    // this just makes the failure reason inspectable instead of log-only.
    private var lastError: CloudASRError?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // Gate 2.4: store the first typed failure of the session; later errors
    // (e.g. cleanup sends after teardown) never overwrite the primary cause.
    private func recordError(_ error: CloudASRError) {
        withLock {
            guard lastError == nil else { return }
            lastError = error
        }
    }

    /// Gate 2.4: typed failure reason of the last finalize, if any.
    /// Lets callers distinguish invalid-key/rate-limit/network from empty
    /// speech without parsing log strings. Read-only, thread-safe.
    func lastLiveError() -> CloudASRError? {
        withLock { lastError }
    }

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        let isFirst = withLock {
            self.onPartial = onPartial
            let first = !isAlive
            if first {
                isAlive = true
                accumulatedText = ""
                isConnected = false
                setupCompleteReceived = false
                pendingAudioQueue.removeAll()
                lastError = nil
            }
            return first
        }

        if isFirst {
            startLiveConnection()
        }

        guard let pcm16 = WAVWriter.pcm16Data(from: buffer) else { return }

        withLock {
            if isConnected && setupCompleteReceived {
                sendAudioChunk(pcm16)
            } else {
                pendingAudioQueue.append(pcm16)
                // Bounded queue (drop-oldest): cap reached → evict oldest chunk.
                while pendingAudioQueue.count > Self.maxPendingChunks {
                    pendingAudioQueue.removeFirst()
                    pendingDroppedCount += 1
                    NSLog("[SingAR] Gemini Live pre-connect queue full (cap \(Self.maxPendingChunks) chunks); dropped oldest (total dropped: \(pendingDroppedCount))")
                }
            }
        }
    }

    // MARK: WebSocket Connection

    private func startLiveConnection() {
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else {
            NSLog("[SingAR] ⚠️ Google API key is missing for Gemini Live streaming")
            recordError(.missingKey)
            return
        }

        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            recordError(.emptySpeech)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        sendSetupMessage()
        listenForResponses()
    }

    private func sendSetupMessage() {
        let languageRule: String
        switch settings.language {
        case .auto:
            languageRule = "Transcribe the incoming audio stream in its exact original spoken language (auto-detecting Russian in Cyrillic, and English in Latin for tech/programming words). NEVER translate Russian speech into English or vice-versa."
        case .ru:
            languageRule = "Transcribe the incoming audio stream in Russian using the Cyrillic alphabet, preserving English only for code and programming terms. NEVER translate Russian speech into English."
        case .en:
            languageRule = "Transcribe the incoming audio stream in English."
        }

        let setupPayload: [String: Any] = [
            "setup": [
                "model": "models/gemini-3.5-transcribe-live",
                "generationConfig": [
                    "responseModalities": ["TEXT"],
                    "temperature": 0.0
                ],
                "systemInstruction": [
                    "parts": [
                        [
                            "text": "You are a high-precision speech-to-text transcriber for a programmer. \(languageRule) Output ONLY the raw transcription with natural punctuation, camelCase, snake_case, and file paths. Do not reply to questions."
                        ]
                    ]
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: setupPayload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { [weak self] error in
            if let error {
                NSLog("[SingAR] Gemini Live setup send error: \(error)")
                self?.recordError(CloudASRError.from(error))
            }
        }
    }

    private func sendAudioChunk(_ pcmData: Data) {
        let chunkPayload: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": pcmData.base64EncodedString()
                    ]
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: chunkPayload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { error in
            if let error {
                NSLog("[SingAR] Audio chunk send error: \(error)")
            }
        }
    }

    private func sendTurnComplete() {
        let turnPayload: [String: Any] = [
            "clientContent": [
                "turnComplete": true
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: turnPayload),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        let message = URLSessionWebSocketTask.Message.string(jsonString)
        webSocketTask?.send(message) { [weak self] error in
            if let error {
                NSLog("[SingAR] turnComplete send error: \(error)")
                self?.recordError(CloudASRError.from(error))
            }
        }
    }

    private func listenForResponses() {
        webSocketTask?.receive { [weak self] result in
            guard let self, self.isAlive else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.listenForResponses() // Continue listening loop
            case .failure(let error):
                NSLog("[SingAR] Gemini Live WebSocket receive error: \(error)")
                self.recordError(CloudASRError.from(error))
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let d):
            data = d
        @unknown default:
            data = nil
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Check for setupComplete
        if json["setupComplete"] != nil {
            withLock {
                self.isConnected = true
                self.setupCompleteReceived = true
                for chunk in self.pendingAudioQueue {
                    self.sendAudioChunk(chunk)
                }
                self.pendingAudioQueue.removeAll()
            }
            return
        }

        // Check for streamed text from Gemini Live
        if let serverContent = json["serverContent"] as? [String: Any] {
            // 1. Google Gemini Live Transcription uses interimInputTranscription or inputTranscription
            if let interim = serverContent["interimInputTranscription"] as? [String: Any],
               let text = interim["text"] as? String, !text.isEmpty {
                let (current, cb) = withLock {
                    self.accumulatedText = text
                    return (self.accumulatedText, self.onPartial)
                }
                DispatchQueue.main.async {
                    cb?(current)
                }
            } else if let inputTrans = serverContent["inputTranscription"] as? [String: Any],
                      let text = inputTrans["text"] as? String, !text.isEmpty {
                let (current, cb) = withLock {
                    self.accumulatedText = text
                    return (self.accumulatedText, self.onPartial)
                }
                DispatchQueue.main.async {
                    cb?(current)
                }
            } else if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                      let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        let (current, cb) = withLock {
                            self.accumulatedText += text
                            return (self.accumulatedText, self.onPartial)
                        }
                        DispatchQueue.main.async {
                            cb?(current)
                        }
                    }
                }
            }

            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                withLock {
                    if let cont = self.completionContinuation {
                        self.completionContinuation = nil
                        // Gate 2.3: same lexicon normalization as every other engine.
                        let result = CodeLexiconNormalizer.normalize(self.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines))
                        cont.resume(returning: result)
                    }
                }
            }
        }
    }

    func finalize() async -> String {
        // Send turnComplete to Google to finalize recognition
        sendTurnComplete()

        // Graceful audio drain: wait up to 850ms for in-flight audio frames and trailing words
        let deadline = Date().addingTimeInterval(0.85)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            // Task cancellation (Esc) must unfreeze this wait immediately;
            // the cancelled finalize Task never needs the trailing words.
            let hasCont = withLock { self.completionContinuation == nil }
            if !hasCont || Task.isCancelled { break }
        }

        withLock { isAlive = false }

        let text = withLock {
            let result = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulatedText = ""
            onPartial = nil
            return result
        }

        teardown()
        // Gate 2.3: same lexicon normalization as every other engine's final
        // output; idempotent, so a turnComplete-normalized result is safe.
        return CodeLexiconNormalizer.normalize(text)
    }

    func cancel() {
        withLock {
            isAlive = false
            accumulatedText = ""
            onPartial = nil
            pendingAudioQueue.removeAll()
            pendingDroppedCount = 0
            // Gate 2.4: explicit session abort is a typed cancellation, unless
            // a real failure (invalid key, network, ...) already happened.
            if lastError == nil { lastError = .cancelled }
            completionContinuation?.resume(returning: "")
            completionContinuation = nil
        }
        teardown()
    }

    private func teardown() {
        // Mutate connection state under the lock (feed/handleMessage read it
        // from audio/session threads); cancel the socket outside the lock.
        let socket: URLSessionWebSocketTask? = withLock {
            let t = webSocketTask
            webSocketTask = nil
            isConnected = false
            setupCompleteReceived = false
            return t
        }
        socket?.cancel(with: .normalClosure, reason: nil)
    }
}
