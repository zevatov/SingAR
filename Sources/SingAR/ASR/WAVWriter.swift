import AVFoundation

/// Writes a sequence of 16 kHz mono Float32 PCM buffers to a WAV file.
enum WAVWriter {
    static func write(_ buffers: [AVAudioPCMBuffer], to url: URL) throws {
        guard let format = buffers.first?.format else {
            throw NSError(domain: "WAVWriter", code: 1, userInfo: nil)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        for buffer in buffers {
            // Convert Float32 → Int16 in the file's common format.
            if let converted = convertToInt16(buffer) {
                try file.write(from: converted)
            }
        }
    }

    private static func convertToInt16(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false
        ) else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        let dst = out.int16ChannelData![0]
        for i in 0..<frames {
            let clamped = max(-1.0, min(1.0, src[i]))
            dst[i] = Int16(clamped * Float(Int16.max))
        }
        return out
    }
}
