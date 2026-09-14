import AVFoundation
import Foundation
import Speech

/// Pluggable speech-to-text backend. The local engine is on the hot path
/// (instant partials); cloud is an optional follow-up step.
protocol ASREngine {
    /// Stream a chunk; `onPartial` fires with incremental text for live display.
    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void)
    /// Finalize and return the complete transcript for the captured session.
    ///
    /// Gate 2.3 contract: the returned text is the engine's final output and
    /// has already been passed through `CodeLexiconNormalizer.normalize`, so
    /// every streaming path (local Speech, Gemini live) yields the same
    /// post-normalization shape. `normalize` is idempotent, so callers may
    /// safely re-run it on the result.
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

    /// Этап 2: буфер ранних кадров. `startSession`/`beginTask` асинхронны
    /// (main-hop + авторизация + locale), а tap шлёт кадры сразу — первые
    /// 100–200мс терялись (`request` ещё nil). Ранние кадры копятся в
    /// `earlyFrames` (cap `maxEarlyFrames`) и сливаются в `request` при
    /// `beginTask`. Cap защищает от unbounded-роста при denied-авторизации.
    static let maxEarlyFrames = 32
    private var earlyFrames: [AVAudioPCMBuffer] = []
    /// Этап 2: offline-seam политики раннего буфера (без AVAudio/SFSpeech).
    /// Возвращает (kept, droppedOldest) для потока входящих кадров при cap.
    static func earlyFramePlan(incoming: Int, alreadyBuffered: Int, cap: Int = maxEarlyFrames) -> (kept: Int, droppedOldest: Int) {
        let total = alreadyBuffered + incoming
        guard total > cap else { return (incoming, 0) }
        let dropped = total - cap
        return (incoming - dropped, dropped)
    }

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        let start = withLock {
            self.onPartial = onPartial
            let s = !isAlive
            if s {
                isAlive = true
                committedText = ""
                segmentText = ""
                earlyFrames.removeAll()
            }
            return s
        }

        if start {
            // Первый кадр — сразу в ранний буфер синхронно (не теряется),
            // затем асинхронный старт сессии сольёт его в request.
            withLock {
                earlyFrames.append(buffer)
                while earlyFrames.count > Self.maxEarlyFrames {
                    earlyFrames.removeFirst()
                }
            }
            DispatchQueue.main.async { [weak self] in self?.startSession() }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let req = self.request {
                req.append(buffer)
            } else {
                self.withLock {
                    self.earlyFrames.append(buffer)
                    while self.earlyFrames.count > Self.maxEarlyFrames {
                        self.earlyFrames.removeFirst()
                    }
                }
            }
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
        // Этап 2: слить ранние кадры (100–200мс) в свежий request — не теряются.
        let early: [AVAudioPCMBuffer] = withLock {
            let e = earlyFrames
            earlyFrames.removeAll()
            return e
        }
        request = req
        for buf in early {
            req.append(buf)
        }
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
            // Task cancellation (Esc) must break the wait immediately so a
            // cancelled finalize Task never blocks for the full grace period.
            if withLock({ gotFinal }) || Task.isCancelled { break }
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
        // Gate 2.3: apply the code lexicon normalizer to the final output so
        // the local Speech path matches every other engine's contract; also
        // strips ASR hallucination lines.
        return CodeLexiconNormalizer.normalize(text)
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
    /// Этап 0: единая trim+isEmpty проверка через SecretStore.hasKey (было:
    /// `get(...) != nil` без trim — пробельный ключ считался валидным).
    var available: Bool {
        switch settings.cloudModel {
        case .localWhisperTurbo:
            return ModelDownloadManager.shared.isModelInstalled
        case .gemini35Transcribe:
            return SecretStore.hasKey(SecretStore.Account.googleApiKey)
        case .gpt4oTranscribe:
            return SecretStore.hasKey(SecretStore.Account.openrouterKey)
        case .groqWhisper:
            return SecretStore.hasKey(SecretStore.Account.groqApiKey)
        case .localOnly:
            return false
        }
    }

    // MARK: Primary Audio Transcription pass

    func cloudTranscribe(audio: Data) async -> String? {
        let result = await cloudTranscribeResult(audio: audio)
        if case .success(let text) = result { return text }
        return nil
    }

    /// Gate 1.7: typed-error variant of `cloudTranscribe`. The legacy `String?`
    /// API above is preserved unchanged for existing call sites; new callers
    /// that need to surface WHY cloud failed use this one. A successful empty
    /// string is impossible — `.emptySpeech` is returned instead.
    ///
    /// Gate 2.3 contract: every successful text returned here has already been
    /// passed through `CodeLexiconNormalizer.normalize` inside each provider
    /// (Gemini / OpenRouter / Groq / local whisper), same as the streaming
    /// engines' `finalize()`.
    func cloudTranscribeResult(audio: Data) async -> Result<String, CloudASRError> {
        switch settings.cloudModel {
        case .localWhisperTurbo:
            // Local whisper keeps its existing diagnostics; it cannot produce
            // the cloud HTTP error taxonomy, so failures map to `.emptySpeech`.
            let text = await transcribeWithLocalWhisper(audio: audio)
            if let text, !text.isEmpty { return .success(text) }
            return .failure(.emptySpeech)
        case .gemini35Transcribe:
            return await transcribeWithGoogleGeminiTyped(audio: audio)
        case .gpt4oTranscribe:
            return await transcribeWithOpenRouterTyped(audio: audio)
        case .groqWhisper:
            return await transcribeWithGroqTyped(audio: audio)
        case .localOnly:
            return .failure(.missingKey)
        }
    }

    // MARK: Этап 2 — отмена сети

    /// Этап 2: явная отмена сети при Esc. `URLSession.shared.data(for:)` уже
    /// наследует отмену Task, но здесь отмена проверяется ЯВНО до/после сети:
    /// `Task.checkCancellation()` до запроса + маппинг `URLError.cancelled` →
    /// `.cancelled` после (через `CloudASRError.from`). Поведение сохранено:
    /// отмена = typed `.cancelled`, контроллер падает на live/local текст
    /// (Gate 0 fallback). Все 4 сетевых пути CloudASR (polish/Gemini/
    /// OpenRouter/Groq) идут через этот helper — отмена запроса сессии
    /// гарантирована везде. Scope Этапа 2 — только CloudASR; verifyGeminiKey
    /// в SettingsView (Этап 3, дебаунс) не трогаем.
    /// Пустой ключ проверяется ЕДИНО через `SecretStore.trimmedKey`
    /// (уже унифицировано в Этапе 0–1: пробельный ключ = `.missingKey`, без сети).
    private func cancellableData(for req: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        do {
            let result = try await URLSession.shared.data(for: req)
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError {
                throw URLError(.cancelled)
            }
            throw error
        }
    }

    // MARK: Ultra-fast Vibe-Coder Text Polish (~150-350ms)

    /// Gate 2.5: legacy `String?` polish API preserved unchanged; nil now
    /// collapses typed failures — callers needing the reason use `polishResult`.
    func polish(text: String) async -> String? {
        if case .success(let p) = await polishResult(text: text) { return p }
        return nil
    }

    /// Gate 2.5: typed-error variant of `polish` (same taxonomy and fallback
    /// contract as `cloudTranscribeResult`): HTTP / network / timeout map to
    /// `CloudASRError`; a successful empty string is impossible —
    /// `.emptySpeech` is returned instead. Callers keep Gate 0 behavior:
    /// any failure means "use the unpolished transcript".
    func polishResult(text: String) async -> Result<String, CloudASRError> {
        guard !text.isEmpty else { return .failure(.emptySpeech) }
        guard let apiKey = SecretStore.trimmedKey(SecretStore.Account.googleApiKey) else { return .failure(.missingKey) }

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

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure(.emptySpeech) }
        // Этап 0: ключ только в заголовке x-goog-api-key (аналогия с Bearer),
        // никогда в query URL — URL без секрета безопасно логировать.
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent") else { return .failure(.emptySpeech) }

        var req = SecretStore.geminiRequest(url: url, apiKey: apiKey)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await cancellableData(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.emptySpeech) }
            guard http.statusCode == 200 else {
                // Gate 2.5: single typed mapping for non-200 statuses.
                let typed = CloudASRError.from(status: http.statusCode)
                NSLog("[SingAR] ⚠️ polish: HTTP %d → %@", http.statusCode, String(describing: typed))
                return .failure(typed)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let polishedText = firstPart["text"] as? String else {
                return .failure(.emptySpeech)
            }

            let trimmed = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failure(.emptySpeech) : .success(trimmed)
        } catch {
            return .failure(CloudASRError.from(error))
        }
    }

    // MARK: Local Whisper (Metal on Apple Silicon)

    /// Hard deadline for the local whisper-cli subprocess. Long enough for the
    /// largest supported model on Apple Silicon; short enough that a hung or
    /// broken binary cannot stall the dictation finalize path forever.
    private static let whisperProcessTimeout: TimeInterval = 120

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
            "--no-fallback",
            "--suppress-nst",
            "-nth", "0.65",
            "--prompt", codingPrompt
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr logs

        let t0 = Date()
        do {
            try process.run()
        } catch {
            AppLogger.shared.log("❌ localWhisper: failed to launch whisper-cli: \(error)")
            return nil
        }

        // Drain stdout/stderr concurrently: without this a chatty child can
        // fill the 64 KB OS pipe buffers and deadlock before it exits.
        let stdoutTask = Task.detached(priority: .userInitiated) {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
        }

        // Bounded wait: poll running-state so a hung or broken whisper-cli can
        // never stall the dictation finalize path forever, and so an aborted
        // dictation Task cancels out promptly instead of blocking.
        let deadline = Date().addingTimeInterval(Self.whisperProcessTimeout)
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                timedOut = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        }

        if timedOut {
            let reason = Task.isCancelled
                ? "dictation task cancelled"
                : "timeout after \(Int(Self.whisperProcessTimeout))s"
            AppLogger.shared.log("⚠️ localWhisper: \(reason) — terminating whisper-cli (pid \(process.processIdentifier))")
            if process.isRunning {
                process.terminate()
                // Short grace period, then force-kill so the subprocess can
                // never outlive the session (SIGKILL cannot be ignored).
                var graceMs = 0
                while process.isRunning && graceMs < 2_000 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    graceMs += 50
                }
                if process.isRunning {
                    // SIGKILL cannot be caught or ignored — the subprocess can
                    // never outlive the session. Harmless if it just exited.
                    _ = kill(process.processIdentifier, SIGKILL)
                }
            }
            AppLogger.shared.log("❌ localWhisper aborted (\(reason)) — falling back to live/local text")
            return nil
        }

        // Normal completion: isRunning == false already, this returns at once.
        process.waitUntilExit()
        let exitCode = process.terminationStatus
        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)

        guard exitCode == 0 else {
            let stderrText = String(data: await stderrTask.value ?? Data(), encoding: .utf8) ?? ""
            AppLogger.shared.log("❌ localWhisper: non-zero termination \(exitCode) (\(elapsed)ms) stderrLen=\(stderrText.count) — falling back to live/local text")
            return nil
        }

        let outData = await stdoutTask.value
        let rawOutput = String(data: outData, encoding: .utf8) ?? ""

        let lines = rawOutput.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                !line.hasPrefix("whisper_") &&
                !line.hasPrefix("main:") &&
                !line.hasPrefix("system_info") &&
                !line.hasPrefix("ggml_") &&
                !CodeLexiconNormalizer.isHallucinationLine(line)
            }

        let rawResult = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawResult.isEmpty {
            // Gate 2.3: same lexicon normalization as every other engine —
            // also strips YouTube hallucination lines.
            let normalized = CodeLexiconNormalizer.normalize(rawResult)
            AppLogger.shared.log("✅ localWhisper: ok (\(elapsed)ms, rawLen=\(rawResult.count), outLen=\(normalized.count))")
            return normalized.isEmpty ? nil : normalized
        }
        AppLogger.shared.log("⚠️ localWhisper: empty output (\(elapsed)ms)")
        return nil
    }

    // MARK: Google Gemini 3.5 Transcribe API

    /// Gate 1.7: typed-error Gemini pass. Legacy `transcribeWithGoogleGemini`
    /// delegates here and maps failure to `nil`, preserving its old contract.
    private func transcribeWithGoogleGeminiTyped(audio: Data) async -> Result<String, CloudASRError> {
        guard let apiKey = SecretStore.trimmedKey(SecretStore.Account.googleApiKey) else {
            NSLog("[SingAR] ❌ cloudTranscribe: Google API Key is MISSING")
            return .failure(.missingKey)
        }
        return await transcribeWithGoogleGeminiInner(audio: audio, apiKey: apiKey)
    }

    private func transcribeWithGoogleGemini(audio: Data) async -> String? {
        guard let apiKey = SecretStore.trimmedKey(SecretStore.Account.googleApiKey) else {
            NSLog("[SingAR] ❌ cloudTranscribe: Google API Key is MISSING")
            return nil
        }
        if case .success(let text) = await transcribeWithGoogleGeminiInner(audio: audio, apiKey: apiKey) {
            return text
        }
        return nil
    }

    private func transcribeWithGoogleGeminiInner(audio: Data, apiKey: String) async -> Result<String, CloudASRError> {

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
            return .failure(.emptySpeech)
        }

        // Primary Google Gemini 3.5 Transcribe model
        let modelsToTry = [
            "gemini-3.5-transcribe"
        ]

        for modelName in modelsToTry {
            // Этап 0: ключ только в заголовке, URL без секрета (см. polishResult).
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent") else { continue }

            var req = SecretStore.geminiRequest(url: url, apiKey: apiKey)
            req.httpMethod = "POST"
            req.httpBody = body
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let t0 = Date()
            NSLog("[SingAR] 🚀 cloudTranscribe: calling model=%@ ...", modelName)

            do {
                let (data, response) = try await cancellableData(for: req)
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                guard let http = response as? HTTPURLResponse else {
                    NSLog("[SingAR] ❌ cloudTranscribe: no HTTP response from %@ (%dms)", modelName, elapsed)
                    return .failure(.network(underlying: URLError(.badServerResponse)))
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
                            // Gate 2.3: same lexicon normalization as every other engine.
                            let normalized = CodeLexiconNormalizer.normalize(cleaned)
                            NSLog("[SingAR] ✅ cloudTranscribe: SUCCESS model=%@ len=%d (%dms)", modelName, normalized.count, elapsed)
                            return normalized.isEmpty ? .failure(.emptySpeech) : .success(normalized)
                        } else {
                            NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ returned empty text", modelName)
                            return .failure(.emptySpeech)
                        }
                    } else {
                        let rawStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ 200 but parse failed, bodyLen=%d", modelName, rawStr.count)
                        return .failure(.emptySpeech)
                    }
                } else {
                    // Gate 1.7: single typed mapping for all non-200 statuses
                    // (was: separate 404 / 429 / else branches that all dropped
                    // the reason on the floor and returned nil).
                    let typed = CloudASRError.from(status: http.statusCode)
                    NSLog("[SingAR] ⚠️ cloudTranscribe: model=%@ HTTP %d → %@", modelName, http.statusCode, String(describing: typed))
                    return .failure(typed)
                }
            } catch {
                let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
                NSLog("[SingAR] ❌ cloudTranscribe: model=%@ error after %dms: %@", modelName, elapsed, error.localizedDescription)
                return .failure(CloudASRError.from(error))
            }
        }

        NSLog("[SingAR] ❌ cloudTranscribe: all models exhausted, returning emptySpeech")
        return .failure(.emptySpeech)
    }

    // MARK: OpenRouter Fallback

    private func transcribeWithOpenRouter(audio: Data) async -> String? {
        guard let key = SecretStore.trimmedKey(SecretStore.Account.openrouterKey) else { return nil }
        if case .success(let text) = await transcribeWithOpenRouterInner(audio: audio, key: key) {
            return text
        }
        return nil
    }

    /// Gate 1.7: typed OpenRouter pass (HTTP statuses preserved, not flattened).
    private func transcribeWithOpenRouterTyped(audio: Data) async -> Result<String, CloudASRError> {
        guard let key = SecretStore.trimmedKey(SecretStore.Account.openrouterKey) else { return .failure(.missingKey) }
        return await transcribeWithOpenRouterInner(audio: audio, key: key)
    }

    private func transcribeWithOpenRouterInner(audio: Data, key: String) async -> Result<String, CloudASRError> {
        let payload: [String: Any] = [
            "model": "openai/gpt-4o-transcribe",
            "input_audio": ["data": audio.base64EncodedString(), "format": "wav"],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .failure(.emptySpeech) }

        guard let url = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions") else { return .failure(.emptySpeech) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await cancellableData(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network(underlying: URLError(.badServerResponse)))
            }
            guard http.statusCode == 200 else {
                let typed = CloudASRError.from(status: http.statusCode)
                NSLog("[SingAR] ⚠️ openrouter: HTTP %d → %@", http.statusCode, String(describing: typed))
                return .failure(typed)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                // Gate 2.3: same lexicon normalization as every other engine.
                let normalized = CodeLexiconNormalizer.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
                return normalized.isEmpty ? .failure(.emptySpeech) : .success(normalized)
            }
            return .failure(.emptySpeech)
        } catch {
            return .failure(CloudASRError.from(error))
        }
    }

    // MARK: Groq Whisper API

    private func transcribeWithGroq(audio: Data) async -> String? {
        guard let key = SecretStore.trimmedKey(SecretStore.Account.groqApiKey) else { return nil }
        if case .success(let text) = await transcribeWithGroqInner(audio: audio, key: key) {
            return text
        }
        return nil
    }

    /// Gate 1.7: typed Groq pass (HTTP statuses preserved, not flattened).
    private func transcribeWithGroqTyped(audio: Data) async -> Result<String, CloudASRError> {
        guard let key = SecretStore.trimmedKey(SecretStore.Account.groqApiKey) else { return .failure(.missingKey) }
        return await transcribeWithGroqInner(audio: audio, key: key)
    }

    private func transcribeWithGroqInner(audio: Data, key: String) async -> Result<String, CloudASRError> {
        guard let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions") else { return .failure(.emptySpeech) }
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
            let (data, response) = try await cancellableData(for: req)
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network(underlying: URLError(.badServerResponse)))
            }
            guard http.statusCode == 200 else {
                let typed = CloudASRError.from(status: http.statusCode)
                NSLog("[SingAR] ⚠️ groqWhisper: HTTP %d → %@", http.statusCode, String(describing: typed))
                return .failure(typed)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                // Gate 2.3: same lexicon normalization as every other engine.
                let normalized = CodeLexiconNormalizer.normalize(text.trimmingCharacters(in: .whitespacesAndNewlines))
                NSLog("[SingAR] ✅ groqWhisper: SUCCESS len=%d (%dms)", normalized.count, elapsed)
                return normalized.isEmpty ? .failure(.emptySpeech) : .success(normalized)
            }
            return .failure(.emptySpeech)
        } catch {
            return .failure(CloudASRError.from(error))
        }
    }
}
