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

    private var pendingAudioQueue: [Data] = []
    private var setupCompleteReceived = false
    private var completionContinuation: CheckedContinuation<String, Never>?

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
            }
        }
    }

    // MARK: WebSocket Connection

    private func startLiveConnection() {
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else {
            NSLog("[SingAR] ⚠️ Google API key is missing for Gemini Live streaming")
            return
        }

        let urlString = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return }

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
        webSocketTask?.send(message) { error in
            if let error {
                NSLog("[SingAR] Gemini Live setup send error: \(error)")
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
        webSocketTask?.send(message) { error in
            if let error {
                NSLog("[SingAR] turnComplete send error: \(error)")
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
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
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
                        let result = self.accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: result)
                    }
                }
            }
        }
    }

    func finalize() async -> String {
        withLock { isAlive = false }

        // Send turnComplete to Google to finalize recognition
        sendTurnComplete()

        // Wait up to 500ms for final server response
        try? await Task.sleep(nanoseconds: 350_000_000)

        let text = withLock {
            let result = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulatedText = ""
            onPartial = nil
            return result
        }

        teardown()
        return text
    }

    func cancel() {
        withLock {
            isAlive = false
            accumulatedText = ""
            onPartial = nil
            pendingAudioQueue.removeAll()
            completionContinuation?.resume(returning: "")
            completionContinuation = nil
        }
        teardown()
    }

    private func teardown() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        setupCompleteReceived = false
    }
}
