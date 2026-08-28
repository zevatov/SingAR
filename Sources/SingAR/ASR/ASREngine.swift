import AVFoundation
import Foundation
import Speech

/// Pluggable speech-to-text backend. The local engine is on the hot path
/// (instant partials); cloud is an optional follow-up step.
protocol ASREngine {
    /// Stream a chunk; `onPartial` fires with incremental text for live display.
    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void)
    /// Finalize and return the complete transcript for the captured session.
    func finalize() async -> String
    /// Stop the partial-streaming loop and drop captured audio without running
    /// a final inference. Used when dictation is aborted (e.g. focus lost).
    func cancel()
}

/// Local ASR via Apple's `SFSpeechRecognizer` — on-device speech recognition
/// that streams partial results natively (0ms latency, free, offline, private).
final class SpeechEngine: ASREngine {

    private let settings = AppSettings.shared

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var committedText = ""
    private var segmentText = ""
    private var onPartial: ((String) -> Void)?
    private var isAlive = false
    private var gotFinal = false
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        let start = withLock {
            self.onPartial = onPartial
            let s = !isAlive
            if s {
                isAlive = true
                committedText = ""
                segmentText = ""
            }
            return s
        }

        if start {
            DispatchQueue.main.async { [weak self] in self?.startSession() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.request?.append(buffer)
        }
    }

    private func startSession() {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            NSLog("[SingAR] speech recognition not authorized — skip session")
            return
        }

        let locale: Locale
        switch settings.language {
        case .auto: locale = Locale(identifier: "ru-RU")
        case .ru:   locale = Locale(identifier: "ru-RU")
        case .en:   locale = Locale(identifier: "en-US")
        }
        guard let rec = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            NSLog("[SingAR] SFSpeechRecognizer unavailable for locale \(locale.identifier)")
            return
        }
        recognizer = rec
        beginTask()
    }

    private func beginTask() {
        guard let rec = recognizer else { return }
        withLock { gotFinal = false }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = settings.autoPunctuation
        request = req
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            NSLog("[SingAR] SFSpeech error: \(error.localizedDescription)")
        }
        if let result {
            let text = result.bestTranscription.segments
                .map { $0.substring }.joined(separator: " ")
            let (full, cb, alive, live) = withLock {
                if !segmentText.isEmpty, !text.isEmpty,
                   commonPrefixLen(segmentText, text) == 0,
                   text.count * 2 < segmentText.count {
                    committedText = currentTranscript()
                }
                segmentText = text
                return (currentTranscript(), onPartial, isAlive, settings.livePartials)
            }
            if alive, live, let cb { cb(full) }
        }
        if result?.isFinal == true || error != nil {
            let alive = withLock {
                gotFinal = true
                if !segmentText.isEmpty {
                    committedText = currentTranscript()
                    segmentText = ""
                }
                return isAlive
            }
            if alive {
                DispatchQueue.main.async { [weak self] in self?.beginTask() }
            }
        }
    }

    private func currentTranscript() -> String {
        if committedText.isEmpty { return segmentText }
        if segmentText.isEmpty { return committedText }
        return committedText + " " + segmentText
    }

    private func commonPrefixLen(_ a: String, _ b: String) -> Int {
        var n = 0
        var ai = a.startIndex, bi = b.startIndex
        while ai < a.endIndex, bi < b.endIndex, a[ai] == b[bi] {
            n += 1; a.formIndex(after: &ai); b.formIndex(after: &bi)
        }
        return n
    }

    func finalize() async -> String {
        withLock { isAlive = false }

        await MainActor.run { [weak self] in
            self?.request?.endAudio()
        }
        let deadline = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            if withLock({ gotFinal }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let text = withLock {
            let t = currentTranscript()
            committedText = ""
            segmentText = ""
            gotFinal = false
            onPartial = nil
            return t
        }

        await MainActor.run { [weak self] in self?.teardown() }
        return text
    }

    func cancel() {
        withLock {
            isAlive = false
            gotFinal = false
            committedText = ""
            segmentText = ""
            onPartial = nil
        }
        DispatchQueue.main.async { [weak self] in self?.teardown() }
    }

    private func teardown() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recognizer = nil
    }
}

/// Cloud speech recognition and cleanup orchestrator.
/// Native support for Google Gemini 3.5 Transcribe (BYOK Free Tier).
final class CloudASR {

    private let settings = AppSettings.shared

    // MARK: Availability

    /// Cloud cleanup is available when a key is configured for the selected model.
    var available: Bool {
        switch settings.cloudModel {
        case .gemini35Transcribe:
            return SecretStore.get(SecretStore.Account.googleApiKey) != nil
        case .gpt4oTranscribe:
            return SecretStore.get(SecretStore.Account.openrouterKey) != nil
        case .localOnly:
            return false
        }
    }

    // MARK: Cloud transcription

    func cloudTranscribe(audio: Data) async -> String? {
        guard settings.cloudCleanup else { return nil }

        switch settings.cloudModel {
        case .gemini35Transcribe:
            return await transcribeWithGoogleGemini(audio: audio)
        case .gpt4oTranscribe:
            return await transcribeWithOpenRouter(audio: audio)
        case .localOnly:
            return nil
        }
    }

    // MARK: Ultra-fast Text Polish via Gemini (~150-250ms)

    func polish(text: String) async -> String? {
        guard settings.cloudCleanup, !text.isEmpty else { return nil }
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else { return nil }

        let languageRule: String
        switch settings.language {
        case .auto:
            languageRule = "Format Russian in Cyrillic and English in Latin for tech words. Do NOT translate."
        case .ru:
            languageRule = "Format primarily in Russian Cyrillic, keeping code/tech terms in English. Do NOT translate to English."
        case .en:
            languageRule = "Format in English."
        }

        let promptText = """
        You are a fast speech text polisher for a developer.
        Format and punctuate this dictated text:
        1. Fix punctuation, capitalization, and grammatical structure naturally.
        2. Preserve programming variable names (camelCase, snake_case), file paths (e.g. /usr/bin), and technical commands.
        3. Remove spoken filler sounds (ээ, мм, ну).
        4. \(languageRule)
        5. Output ONLY the polished text. No explanations, no markdown fences, no quotes.

        Text:
        \(text)
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "maxOutputTokens": 1024
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let polishedText = firstPart["text"] as? String else {
                return nil
            }

            return polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // MARK: Google Gemini 3.5 Transcribe API

    private func transcribeWithGoogleGemini(audio: Data) async -> String? {
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else {
            NSLog("[SingAR] Google API Key is missing")
            return nil
        }

        let languageRule: String
        switch settings.language {
        case .auto:
            languageRule = "Match the spoken language (Russian in Cyrillic, English in Latin, or mixed tech terminology). Do NOT translate Russian to English."
        case .ru:
            languageRule = "Transcribe in Russian (Cyrillic), preserving code/tech terms in English. Do NOT translate Russian to English."
        case .en:
            languageRule = "Transcribe in English."
        }

        // System prompt for code-aware dictation & punctuation
        let promptText = """
        You are a high-precision speech-to-text transcriber for a programmer.
        Accurately transcribe the attached audio recording.
        Rules:
        1. Output ONLY the raw transcribed text. Do NOT include markdown code fences, notes, explanations, or quotes.
        2. Preserve code elements, programming syntax, variable names (camelCase, snake_case), slashes in file paths (e.g. /usr/bin, src/app.ts), and punctuation naturally.
        3. \(languageRule)
        """

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": audio.base64EncodedString()
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        // Primary Google Gemini 3.5 Transcribe model
        let modelsToTry = [
            "gemini-3.5-transcribe",
            "gemini-3.6-flash"
        ]

        for modelName in modelsToTry {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: urlString) else { continue }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }

                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let firstCandidate = candidates.first,
                       let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let firstPart = parts.first,
                       let text = firstPart["text"] as? String {
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            return cleaned
                        }
                    }
                } else if http.statusCode == 404 {
                    // Try next model fallback
                    NSLog("[SingAR] Google model \(modelName) returned 404, falling back...")
                    continue
                } else {
                    NSLog("[SingAR] Google Gemini HTTP error: \(http.statusCode)")
                    return nil
                }
            } catch {
                NSLog("[SingAR] Google Gemini request error: \(error)")
                return nil
            }
        }

        return nil
    }

    // MARK: OpenRouter Fallback

    private func transcribeWithOpenRouter(audio: Data) async -> String? {
        guard let key = SecretStore.get(SecretStore.Account.openrouterKey), !key.isEmpty else { return nil }

        let payload: [String: Any] = [
            "model": "openai/gpt-4o-transcribe",
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        guard let url = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        } catch {
            return nil
        }
    }
}
