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

    /// Cloud cleanup / ASR is available when configured for the selected model.
    var available: Bool {
        switch settings.cloudModel {
        case .localWhisperTurbo:
            return ModelDownloadManager.shared.isModelInstalled
        case .gemini35Transcribe:
            return SecretStore.get(SecretStore.Account.googleApiKey) != nil
        case .gpt4oTranscribe:
            return SecretStore.get(SecretStore.Account.openrouterKey) != nil
        case .groqWhisper:
            return SecretStore.get(SecretStore.Account.groqApiKey) != nil
        case .localOnly:
            return false
        }
    }

    // MARK: Primary Audio Transcription pass

    func cloudTranscribe(audio: Data) async -> String? {
        switch settings.cloudModel {
        case .localWhisperTurbo:
            return await transcribeWithLocalWhisper(audio: audio)
        case .gemini35Transcribe:
            return await transcribeWithGoogleGemini(audio: audio)
        case .gpt4oTranscribe:
            return await transcribeWithOpenRouter(audio: audio)
        case .groqWhisper:
            return await transcribeWithGroq(audio: audio)
        case .localOnly:
            return nil
        }
    }

    // MARK: Ultra-fast Vibe-Coder Text Polish (~150-350ms)

    func polish(text: String) async -> String? {
        guard !text.isEmpty else { return nil }
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else { return nil }

        let languageRule: String
        switch settings.language {
        case .auto:
            languageRule = "Format Russian in Cyrillic and English in Latin for tech words and code. Do NOT translate Russian sentences to English."
        case .ru:
            languageRule = "Format primarily in Russian Cyrillic, keeping code/tech terms and commands in English. Do NOT translate Russian to English."
        case .en:
            languageRule = "Format in English."
        }

        let promptText = """
        You are an elite code and terminal text formatter for a developer (vibe coder).
        Format and punctuate this dictated text:
        1. Fix technical commands and CLI flags: preserve exact syntax, e.g. git status --short, npm run build, docker compose up -d, npx, cargo.
        2. Fix file paths and env files: e.g. src/components/Sidebar.tsx, .env, package.json, /usr/local/bin.
        3. Fix programming identifiers: camelCase (handleClick, getUser), UPPER_SNAKE_CASE (DATABASE_URL), PascalCase.
        4. If technical terms or code were phonetically transcribed in Russian Cyrillic (e.g. 'нпм ран билд', 'гит статус шорт', 'хэндл клик', 'сайдбар'), CONVERT them to proper English code (e.g. 'npm run build', 'git status --short', 'handleClick', 'Sidebar').
        5. \(languageRule) Preserve developer anglicisms naturally (запушь в origin main, закоммить, задеплой, мердж реквест).
        6. Remove vocal filler sounds (ээ, мм, ну).
        7. Output ONLY the polished text. No explanations, no markdown fences, no quotes.

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
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 6
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

    // MARK: Local Whisper (Metal on Apple Silicon)

    private func transcribeWithLocalWhisper(audio: Data) async -> String? {
        guard let modelPath = ModelDownloadManager.shared.activeModelPath else {
            NSLog("[SingAR] ❌ localWhisper: model not found")
            return nil
        }

        // Find whisper-cli executable
        let possibleBins = [
            Bundle.main.resourceURL?.appendingPathComponent("whisper-cli").path,
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ].compactMap { $0 }

        guard let whisperBin = possibleBins.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            NSLog("[SingAR] ❌ localWhisper: whisper-cli binary not found in standard paths")
            return nil
        }

        let tmpWav = FileManager.default.temporaryDirectory.appendingPathComponent("singar-whisper-\(UUID().uuidString).wav")
        do {
            try audio.write(to: tmpWav)
        } catch {
            NSLog("[SingAR] ❌ localWhisper: failed to write tmp WAV: \(error)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpWav) }

        let lang = settings.language == .en ? "en" : "ru"
        let codingPrompt = "npm run build, Sidebar.tsx, handleClick, git status --short, docker compose up -d, .env, origin main, cargo, npx, API, JSON, URL, camelCase, snake_case, TypeScript, React, Python, commit, deploy"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBin)
        process.arguments = [
            "-m", modelPath,
            "-f", tmpWav.path,
            "-l", lang,
            "-nt",
            "--prompt", codingPrompt
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr logs

        let t0 = Date()
        do {
            try process.run()
            process.waitUntilExit()

            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let rawOutput = String(data: outData, encoding: .utf8) ?? ""

            let lines = rawOutput.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { line in
                    !line.isEmpty &&
                    !line.hasPrefix("whisper_") &&
                    !line.hasPrefix("main:") &&
                    !line.hasPrefix("system_info") &&
                    !line.hasPrefix("ggml_")
                }

            let rawResult = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawResult.isEmpty {
                // Apply local fast lexicon normalization for common tech terms
                let normalized = CodeLexiconNormalizer.normalize(rawResult)
                NSLog("[SingAR] ✅ localWhisper: SUCCESS text=\"%@\" (%dms)", String(normalized.prefix(80)), elapsed)
                return normalized
            }
            return nil
        } catch {
            NSLog("[SingAR] ❌ localWhisper process error: \(error)")
            return nil
        }
    }

    // MARK: Google Gemini 3.5 Transcribe API

    private func transcribeWithGoogleGemini(audio: Data) async -> String? {
        guard let apiKey = SecretStore.get(SecretStore.Account.googleApiKey), !apiKey.isEmpty else {
            NSLog("[SingAR] ❌ cloudTranscribe: Google API Key is MISSING")
            return nil
        }

        NSLog("[SingAR] 🎤 cloudTranscribe: audio size = %d bytes (%.1f KB base64)", audio.count, Double(audio.count) * 4.0 / 3.0 / 1024.0)

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

        let audioBase64 = audio.base64EncodedString()

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": promptText],
                        [
                            "inline_data": [
                                "mime_type": "audio/wav",
                                "data": audioBase64
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            NSLog("[SingAR] ❌ cloudTranscribe: JSON serialization failed")
            return nil
        }

        // Primary Google Gemini 3.5 Transcribe model
        let modelsToTry = [
            "gemini-3.5-transcribe"
        ]

        for modelName in modelsToTry {
            let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
            guard let url = URL(string: urlString) else { continue }

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let t0 = Date()
            NSLog("[SingAR] 🚀 cloudTranscribe: calling model=%@ ...", modelName)

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                guard let http = response as? HTTPURLResponse else {
                    NSLog("[SingAR] ❌ cloudTranscribe: no HTTP response from %@ (%dms)", modelName, elapsed)
                    continue
                }

                NSLog("[SingAR] 📡 cloudTranscribe: model=%@ status=%d elapsed=%dms responseSize=%d", modelName, http.statusCode, elapsed, data.count)

                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let candidates = json["candidates"] as? [[String: Any]],
                       let firstCandidate = candidates.first,
                       let content = firstCandidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]],
                       let firstPart = parts.first {

                        // Google Gemini 3.5 Transcribe returns { "audioTranscription": { "text": "..." } }
                        var extractedText: String?
                        if let audioTranscription = firstPart["audioTranscription"] as? [String: Any],
                           let t = audioTranscription["text"] as? String {
                            extractedText = t
                        } else if let t = firstPart["text"] as? String {
                            extractedText = t
                        }

                        if let cleaned = extractedText?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty {
                            NSLog("[SingAR] ✅ cloudTranscribe: SUCCESS model=%@ text=\"%@\" (%dms)", modelName, String(cleaned.prefix(80)), elapsed)
                            return cleaned
                        } else {
                            NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ returned empty text", modelName)
                            continue
                        }
                    } else {
                        let rawStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ 200 but parse failed. Raw: %@", modelName, String(rawStr.prefix(300)))
                        continue
                    }
                } else if http.statusCode == 404 {
                    NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ returned 404", modelName)
                    continue
                } else if http.statusCode == 429 {
                    NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ rate limited (429)", modelName)
                    continue
                } else {
                    let rawStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    NSLog("[SingAR] ❌ cloudTranscribe: model=%@ HTTP %d: %@", modelName, http.statusCode, String(rawStr.prefix(200)))
                    continue
                }
            } catch {
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                NSLog("[SingAR] ❌ cloudTranscribe: model=%@ error after %dms: %@", modelName, elapsed, error.localizedDescription)
                continue
            }
        }

        NSLog("[SingAR] ❌ cloudTranscribe: all models exhausted, returning nil")
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
        req.timeoutInterval = 25
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

    // MARK: Groq Whisper API

    private func transcribeWithGroq(audio: Data) async -> String? {
        guard let key = SecretStore.get(SecretStore.Account.groqApiKey), !key.isEmpty else { return nil }

        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10

        let boundary = "----SingARGroq\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n".data(using: .utf8)!)

        let lang = settings.language == .en ? "en" : "ru"
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n\(lang)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let t0 = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[SingAR] ✅ groqWhisper: SUCCESS text=\"%@\" (%dms)", String(cleaned.prefix(80)), elapsed)
                return cleaned
            }
            return nil
        } catch {
            return nil
        }
    }
}
