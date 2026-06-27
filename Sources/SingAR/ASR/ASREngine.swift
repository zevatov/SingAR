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

/// whisper.cpp backed by the `whisper-cli` binary (CoreML/Metal). For the M1
/// spike we run the CLI as a subprocess over a WAV file; later this becomes an
/// in-process C bridge for true streaming partials.
final class WhisperEngine: ASREngine {

    private let settings = AppSettings.shared
    private var buffers: [AVAudioPCMBuffer] = []

    /// Path to the ggml model. Looked up from a few conventional locations.
    private let modelURL: URL = {
        let candidates = [
            "models/ggml-large-v3-turbo.bin",
            "models/ggml-large-v3.bin",
        ]
        let fm = FileManager.default
        for path in candidates {
            let abs: URL
            if path.hasPrefix("/") {
                abs = URL(fileURLWithPath: path)
            } else {
                abs = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path)
            }
            if fm.fileExists(atPath: abs.path) { return abs }
        }
        // Fall back to the turbo name; finalize() will surface the error.
        return URL(fileURLWithPath: "models/ggml-large-v3-turbo.bin")
    }()

    private var cliPath: String {
        // Homebrew install location; fallback to PATH lookup.
        let fm = FileManager.default
        let brew = "/opt/homebrew/bin/whisper-cli"
        if fm.isExecutableFile(atPath: brew) { return brew }
        return "whisper-cli"
    }

    func feed(_ buffer: AVAudioPCMBuffer, onPartial: @escaping (String) -> Void) {
        // Subprocess mode: just accumulate. Partials come from a future C bridge.
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

        let result = await runCLI(audio: tmp)
        buffers.removeAll()
        try? FileManager.default.removeItem(at: tmp)
        return result
    }

    private func runCLI(audio: URL) async -> String {
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            NSLog("[SingAR] model not found at \(modelURL.path)")
            return ""
        }
        guard FileManager.default.isExecutableFile(atPath: cliPath) || cliPath == "whisper-cli" else {
            NSLog("[SingAR] whisper-cli not found at \(cliPath)")
            return ""
        }

        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath == "whisper-cli" ? "/usr/bin/env" : cliPath)
            var args: [String] = []
            if cliPath == "whisper-cli" {
                args = ["whisper-cli"]
            }
            args += ["-m", modelURL.path, "-f", audio.path, "--no-timestamps", "-nt"]

            // Language: auto unless pinned.
            if settings.language != .auto {
                args += ["-l", settings.language.rawValue]
            }

            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            do {
                try proc.run()
            } catch {
                NSLog("[SingAR] whisper-cli launch failed: \(error)")
                continuation.resume(returning: "")
                return
            }

            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                // whisper-cli prints the transcript as plain lines (with -nt).
                let transcript = raw
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                continuation.resume(returning: transcript)
            }
        }
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
