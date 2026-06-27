import Foundation

/// Manages a long-lived `whisper-server` subprocess that keeps the model
/// resident in memory. This eliminates the ~20s cold start of spawning
/// `whisper-cli` per dictation; inference then takes ~1.7s regardless of how
/// long since the last request.
final class WhisperServerProcess {

    static let shared = WhisperServerProcess()

    private var process: Process?
    private var stoppedManually = false
    private let port: Int = 8080
    private let host: String = "127.0.0.1"

    private var modelURL: URL = {
        let fm = FileManager.default
        // 1. Inside the app bundle (Contents/Resources/models).
        if let bundleModel = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin")
            ?? Bundle.main.url(forResource: "ggml-large-v3", withExtension: "bin") {
            return bundleModel
        }
        // 2. Adjacent models/ directory (dev mode).
        for path in ["models/ggml-large-v3-turbo.bin", "models/ggml-large-v3.bin"] {
            let abs = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path)
            if fm.fileExists(atPath: abs.path) { return abs }
        }
        return URL(fileURLWithPath: "models/ggml-large-v3-turbo.bin")
    }()

    private var cliPath: String {
        let brew = "/opt/homebrew/bin/whisper-server"
        return FileManager.default.isExecutableFile(atPath: brew) ? brew : "whisper-server"
    }

    private init() {}

    /// Start the server if not already running. Returns true on success.
    @discardableResult
    func start() -> Bool {
        guard process == nil else { return true }
        stoppedManually = false
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            NSLog("[SingAR] model not found at \(modelURL.path)")
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath == "whisper-server" ? "/usr/bin/env" : cliPath)
        var args: [String] = []
        if cliPath == "whisper-server" { args.append("whisper-server") }
        args += [
            "-m", modelURL.path,
            "--host", host,
            "--port", String(port),
            "--convert",          // server transcodes via ffmpeg
            "-l", "auto",
            "-nt",
        ]
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()

        // Auto-restart if the server crashes.
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            NSLog("[SingAR] whisper-server exited (\(p.terminationStatus))")
            self.process = nil
            // Relaunch after a brief delay unless we deliberately stopped it.
            guard !self.stoppedManually else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.start()
            }
        }

        do {
            try proc.run()
        } catch {
            NSLog("[SingAR] whisper-server launch failed: \(error)")
            return false
        }
        process = proc
        NSLog("[SingAR] whisper-server started (pid \(proc.processIdentifier)) on \(host):\(port)")
        return true
    }

    /// True if the server is reachable (quick synchronous health probe).
    var isHealthy: Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 2)
        return ok
    }

    /// Stop the server (deliberately — no auto-restart).
    func stop() {
        stoppedManually = true
        process?.terminate()
        process = nil
    }

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}
