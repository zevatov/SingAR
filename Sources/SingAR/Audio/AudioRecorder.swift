import AVFoundation

/// Captures microphone audio via AVAudioEngine and delivers 16 kHz mono
/// Float32 PCM buffers to a callback — the format whisper.cpp expects.
final class AudioRecorder {

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var converter: AVAudioConverter?
    private var isRunning = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        guard !isRunning else { return }
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
    }

    /// All captured PCM since start, for the final ASR pass.
    private(set) var capturedBuffers: [AVAudioPCMBuffer] = []

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
        capturedBuffers.append(out)
        onBuffer?(out)
    }
}
