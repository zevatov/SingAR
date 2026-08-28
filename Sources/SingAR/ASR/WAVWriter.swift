import AVFoundation

/// Writes and converts 16 kHz mono Float32 PCM buffers to WAV files or raw 16-bit PCM bytes.
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
            if let converted = convertToInt16(buffer) {
                try file.write(from: converted)
            }
        }
    }

    /// Converts Float32 PCM buffer into raw 16-bit Linear PCM Data (for Gemini Live WebSocket).
    static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var data = Data(count: frames * 2)
        data.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
            let dst = rawPtr.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<frames {
                let clamped = max(-1.0, min(1.0, src[i]))
                dst[i] = Int16(clamped * Float(Int16.max))
            }
        }
        return data
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
