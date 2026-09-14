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
    // Этап 2: продуктовое решение зафиксировано — DROP-OLDEST + счётчик
    // `pendingDroppedCount` + flush-burst не более `flushBurstCap` (== cap).
    static let maxPendingChunks = 200
    /// Этап 2: burst сброса после `setupComplete` ограничен тем же cap —
    /// 200 WebSocket-send подряд максимум, без unbounded-цикла.
    static let flushBurstCap = 200
    /// Этап 2: reconnect-политика после классифицированной ошибки.
    static let maxReconnectAttempts = 2
    /// Этап 2: pure-seam бэкоффа (ms) для тестов без сети/таймеров.
    static func reconnectBackoffMs(attempt: Int) -> UInt64 {
        switch attempt {
        case 0: return 500
        case 1: return 1_000
        default: return 2_000
        }
    }
    /// Этап 2: pure-seam решения о переподключении (offline-тестируемо).
    /// Переподключаемся только на транспортабельных ошибках и пока есть попытки.
    static func shouldReconnect(error: CloudASRError, attempt: Int) -> Bool {
        guard attempt < maxReconnectAttempts else { return false }
        switch error {
        case .network, .timeout, .serverError: return true
        default: return false
        }
    }
    /// Этап 2: drain-таймаут финализации (ms). Без соединения — 0 (ранний выход,
    /// никакого «всегда +850мс»); с соединением — 850мс максимум с ранним
    /// выходом по `turnComplete`/тексту/отмене.
    static func finalizeDrainMs(connected: Bool) -> UInt64 {
        connected ? 850 : 0
    }
    private var pendingAudioQueue: [Data] = []
    private var pendingDroppedCount = 0
    private var setupCompleteReceived = false
    private var completionContinuation: CheckedContinuation<String, Never>?
    /// Этап 2: флаг конца хода для раннего выхода из drain (убирает «всегда +850мс»).
    /// Ставится в `handleMessage` при `turnComplete=true`, сбрасывается на новой сессии.
    private var turnCompleted = false
    /// Этап 2: инвалидация сессии после демонтажа (37,346). Инкремент на каждой
    /// новой сессии (`feed` first) и на `cancel`/`finalize`/`teardown`; поздние
    /// `handleMessage` с чужим id игнорируются. `urlSession` переиспользуется
    /// между сессиями (не инвалидируется) — сокет пересоздаётся на `feed`.
    private var sessionId = 0
    private var reconnectAttempt = 0

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
                pendingDroppedCount = 0
                lastError = nil
                reconnectAttempt = 0
                turnCompleted = false
                completionContinuation = nil
                sessionId &+= 1
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

    /// Этап 2: offline-seam политики pre-connect очереди (без сети/аудио).
    /// Возвращает (kept, dropped) для потока входящих чанков при cap.
    static func preConnectPlan(incoming: Int, alreadyQueued: Int, cap: Int = maxPendingChunks) -> (kept: Int, dropped: Int) {
        let total = alreadyQueued + incoming
        guard total > cap else { return (incoming, 0) }
        let dropped = total - cap
        return (incoming - dropped, dropped)
    }

    // MARK: WebSocket Connection

    private func startLiveConnection() {
        guard let apiKey = SecretStore.trimmedKey(SecretStore.Account.googleApiKey) else {
            NSLog("[SingAR] ⚠️ Google API key is missing for Gemini Live streaming")
            recordError(.missingKey)
            return
        }

        // Этап 0: ключ только в заголовке x-goog-api-key, никогда в query URL
        // (аналогия с Bearer для OpenRouter/Groq). URL без секрета безопасно логировать.
        guard let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent") else {
            recordError(.emptySpeech)
            return
        }

        var request = SecretStore.geminiRequest(url: url, apiKey: apiKey)
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
                // Этап 1: санитизация — только домен+код, без URL/тел (AppLogger.log ещё раз санитизирует).
                AppLogger.shared.log("Gemini Live setup send error: \(AppLogger.sanitizedError(error))")
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
                // Этап 1: санитизация — только домен+код, без URL/тел.
                AppLogger.shared.log("Audio chunk send error: \(AppLogger.sanitizedError(error))")
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
                // Этап 1: санитизация — только домен+код, без URL/тел.
                AppLogger.shared.log("turnComplete send error: \(AppLogger.sanitizedError(error))")
                self?.recordError(CloudASRError.from(error))
            }
        }
    }

    /// Этап 1: pure-seam санитизации WS-ошибок — только домен+код, без URL/тел.
    /// Используется перед AppLogger.shared.log; покрыт offline-тестом.
    static func sanitizedReceiveError(_ error: Error) -> String {
        AppLogger.sanitizedError(error)
    }

    private func listenForResponses() {
        // Этап 2: sessionId захватывается — поздние ответы демонтированной
        // сессии игнорируются (инвалидация после демонтажа).
        let sid = withLock { sessionId }
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            let alive: Bool = self.withLock { self.isAlive && self.sessionId == sid }
            guard alive else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message, sessionId: sid)
                self.listenForResponses()
            case .failure(let error):
                let typed = CloudASRError.from(error)
                AppLogger.shared.log("Gemini Live WebSocket receive error: \(Self.sanitizedReceiveError(error))")
                self.recordError(typed)
                if Self.shouldReconnect(error: typed, attempt: self.withLock({ self.reconnectAttempt })) {
                    self.scheduleReconnect(sessionId: sid)
                } else {
                    self.listenForResponses()
                }
            }
        }
    }

    private func scheduleReconnect(sessionId sid: Int) {
        let attempt: Int = withLock {
            guard self.sessionId == sid, self.isAlive else { return -1 }
            let a = self.reconnectAttempt
            self.reconnectAttempt += 1
            return a
        }
        guard attempt >= 0 else { return }
        let backoffMs = Self.reconnectBackoffMs(attempt: attempt)
        AppLogger.shared.log("Gemini Live reconnect attempt=\(attempt + 1) backoff=\(backoffMs)ms")
        let old: URLSessionWebSocketTask? = withLock {
            let t = self.webSocketTask
            self.webSocketTask = nil
            self.isConnected = false
            self.setupCompleteReceived = false
            return t
        }
        old?.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(Int(backoffMs))) { [weak self] in
            guard let self else { return }
            let ok: Bool = self.withLock { self.isAlive && self.sessionId == sid }
            guard ok else { return }
            self.startLiveConnection()
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message, sessionId sid: Int? = nil) {
        if let sid {
            let current: Bool = withLock { self.sessionId == sid && self.isAlive }
            guard current else { return }
        }
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
            let toFlush: [Data] = withLock {
                self.isConnected = true
                self.setupCompleteReceived = true
                let burst = Array(self.pendingAudioQueue.prefix(Self.flushBurstCap))
                self.pendingAudioQueue.removeFirst(min(burst.count, self.pendingAudioQueue.count))
                if !self.pendingAudioQueue.isEmpty {
                    NSLog("[SingAR] Gemini Live flush burst capped at \(Self.flushBurstCap); \(self.pendingAudioQueue.count) chunks remain queued")
                }
                return burst
            }
            for chunk in toFlush {
                self.sendAudioChunk(chunk)
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
                    self.turnCompleted = true
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
        // Этап 2: ранний выход без соединения — никакого «всегда +850мс».
        // Drain только при живом сокете, с ранним выходом по концу хода /
        // тексту / отмене (см. `finalizeDrainMs` + `turnCompleted`).
        let connected: Bool = withLock { isConnected && setupCompleteReceived && webSocketTask != nil }
        if connected {
            sendTurnComplete()
            let drainMs = Self.finalizeDrainMs(connected: true)
            let deadline = Date().addingTimeInterval(Double(drainMs) / 1000.0)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let done: Bool = withLock { turnCompleted || Task.isCancelled || !accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if done { break }
                if Task.isCancelled { break }
            }
        } else {
            AppLogger.shared.log("Gemini Live finalize: no live connection — early exit, no 850ms drain")
        }

        withLock {
            isAlive = false
            sessionId &+= 1
        }

        let text = withLock {
            let result = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            accumulatedText = ""
            onPartial = nil
            turnCompleted = false
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
            sessionId &+= 1
            accumulatedText = ""
            onPartial = nil
            pendingAudioQueue.removeAll()
            pendingDroppedCount = 0
            turnCompleted = false
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
        // Этап 2: инвалидация сессии после демонтажа — `sessionId` бампается,
        // поздние `handleMessage`/`listenForResponses` с чужим id дропаются.
        // `urlSession` переиспользуется (не инвалидируется), сокет пересоздаётся на `feed`.
        let socket: URLSessionWebSocketTask? = withLock {
            let t = webSocketTask
            webSocketTask = nil
            isConnected = false
            setupCompleteReceived = false
            sessionId &+= 1
            return t
        }
        socket?.cancel(with: .normalClosure, reason: nil)
    }
}
