import AVFoundation

/// Captures microphone audio via AVAudioEngine and delivers 16 kHz mono
/// Float32 PCM buffers to a callback — the format SFSpeechRecognizer and the
/// cloud WAV path both consume directly.
final class AudioRecorder {

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// PRE-DMG-FIX-CAP: one-shot handler fired on the MAIN queue the first
    /// time a session crosses the local capture budget (never on the realtime
    /// tap thread — the engine must not be controlled from audio callbacks).
    /// Generation-scoped by the controller; cleared in `stop()`.
    var onCaptureLimitReached: (() -> Void)?
    private var converter: AVAudioConverter?
    private var isRunning = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        guard !isRunning else { return }
        // Reset captured audio for the cloud pass: without this, buffers from
        // every previous dictation accumulate across sessions, so the cloud
        // pass would transcribe a concatenation of all past dictations and
        // return stale text (the "erases and inserts past messages" bug).
        // Safe to clear on every fresh start: stopDictation snapshots
        // capturedBuffers synchronously BEFORE its async finalize, so the
        // stopped session's cloud pass already holds its own immutable copy
        // and is unaffected by this clear.
        clearCapturedBuffers()
        self.onBuffer = onBuffer

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.resample(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            NSLog("[SingAR] 🎤 AVAudioEngine started — capturing mic")
        } catch {
            NSLog("[SingAR] AVAudioEngine start failed: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onBuffer = nil
        onCaptureLimitReached = nil
    }

    /// All captured PCM since start, for the final ASR pass (thread-safe).
    /// Bounded to EXACTLY `maxCapturedFrames`: a boundary buffer is trimmed
    /// frame-wise, and the live feed stops at the same edge (the controller's
    /// one-shot auto-finalize takes over from there).
    private var _capturedBuffers: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()

    // Local capture safety budget: 10 minutes of 16 kHz mono Float32 (the
    // known target format) ≈ 9.6M frames ≈ 38 MB. Exact in frames, no byte
    // estimation needed. This is a LOCAL memory-safety budget, NOT a confirmed
    // upstream/API limit. Internal for offline regression tests.
    static let maxCapturedFrames = 10 * 60 * 16_000
    private var _capturedFrames = 0
    private var _droppedFrames = 0
    private var _limitLogged = false

    /// Minimal non-breaking signal upward: true once the capture cap was hit
    /// and in-memory accumulation stopped (stays true until next `start`).
    var didReachCaptureLimit: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _limitLogged
    }

    var capturedBuffers: [AVAudioPCMBuffer] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _capturedBuffers
    }

    func clearCapturedBuffers() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        _capturedBuffers.removeAll()
        _capturedFrames = 0
        _droppedFrames = 0
        _limitLogged = false
    }

    private func resample(_ input: AVAudioPCMBuffer) {
        guard let converter else { return }
        let targetFormat = self.targetFormat

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio)
        guard outFrameCapacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrameCapacity) else { return }

        var error: NSError?
        var fed = false
        let status: AVAudioConverterOutputStatus = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error || error != nil {
            NSLog("[SingAR] audio convert error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        // PRE-DMG-FIX-CAP: the REAL production decision for this converted
        // buffer (shared with offline regression tests — no duplicated
        // formula). The boundary buffer is trimmed frame-exactly; past the
        // budget nothing is kept AND nothing is fed to the live path — the
        // controller's one-shot auto-finalize owns the session from the edge.
        let frames = Int(out.frameLength)
        var deliveredBuffer: AVAudioPCMBuffer? = out
        var fireLimitCallback = false
        bufferLock.lock()
        let plan = AudioRecorder.capturePlan(capturedFrames: _capturedFrames, incomingFrames: frames)
        if plan.keepFrames == frames {
            _capturedBuffers.append(out)
            _capturedFrames += frames
        } else if plan.keepFrames > 0, let trimmed = AudioRecorder.trimmedPrefixCopy(out, frames: plan.keepFrames) {
            _capturedBuffers.append(trimmed)
            _capturedFrames += plan.keepFrames
            deliveredBuffer = trimmed
        } else {
            deliveredBuffer = nil
        }
        if plan.limitEdgeCrossed {
            _droppedFrames += frames - plan.keepFrames
            fireLimitCallback = !_limitLogged
            if !_limitLogged {
                _limitLogged = true
                NSLog("[SingAR] AudioRecorder capture budget reached (10 min @ 16 kHz — LOCAL safety budget, not an API limit); snapshot bounded to exactly \(Self.maxCapturedFrames) frames, live feed stopped, dropped=\(_droppedFrames) frames so far")
            }
        }
        bufferLock.unlock()

        // Live feed receives only in-budget audio (the trimmed prefix at the
        // edge). No new live audio flows while auto-finalize waits on main.
        if let deliveredBuffer {
            onBuffer?(deliveredBuffer)
        }
        if fireLimitCallback, let handler = onCaptureLimitReached {
            // Never controller work on the realtime tap thread: hop to main.
            DispatchQueue.main.async(execute: handler)
        }
    }

    // MARK: PRE-DMG-FIX-CAP: local capture budget (internal for tests)

    /// The single production decision for one converted tap buffer against
    /// the local capture budget. The realtime tap and the regression tests
    /// both call exactly this.
    /// - `keepFrames`: frames admitted into the snapshot store.
    /// - `deliverFrames`: frames handed to the live path (0 ⇒ stop feeding).
    /// - `limitEdgeCrossed`: this buffer pushes the store past the budget
    ///   (one-shot callback dedupe is the caller's job).
    struct CapturePlan: Equatable {
        var keepFrames: Int
        var deliverFrames: Int
        var limitEdgeCrossed: Bool
    }

    static func capturePlan(
        capturedFrames: Int,
        incomingFrames: Int,
        cap: Int = AudioRecorder.maxCapturedFrames
    ) -> CapturePlan {
        let remaining = cap - capturedFrames
        if incomingFrames <= remaining {
            return CapturePlan(keepFrames: incomingFrames, deliverFrames: incomingFrames, limitEdgeCrossed: false)
        }
        let keep = max(0, remaining)
        return CapturePlan(keepFrames: keep, deliverFrames: keep, limitEdgeCrossed: true)
    }

    /// Frame-exact prefix copy owning its storage (never aliases `buffer`).
    /// Returns nil for a `frames` request outside `1...buffer.frameLength`.
    static func trimmedPrefixCopy(_ buffer: AVAudioPCMBuffer, frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, frames <= Int(buffer.frameLength),
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames)),
              let src = buffer.floatChannelData,
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(buffer.format.channelCount) {
            memcpy(dst[ch], src[ch], MemoryLayout<Float>.size * frames)
        }
        return copy
    }
}
