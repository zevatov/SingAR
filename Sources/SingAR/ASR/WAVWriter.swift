import AVFoundation

/// Writes and converts 16 kHz mono Float32 PCM buffers to WAV files or raw 16-bit PCM bytes.
enum WAVWriter {

    /// Fast in-memory 16 kHz Mono 16-bit WAV generation (0 ms disk overhead).
    static func wavData(from buffers: [AVAudioPCMBuffer]) -> Data? {
        guard !buffers.isEmpty else { return nil }
        var pcmData = Data()
        for buffer in buffers {
            if let d = pcm16Data(from: buffer) {
                pcmData.append(d)
            }
        }
        guard !pcmData.isEmpty else { return nil }

        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize: UInt32 = UInt32(pcmData.count)
        let chunkSize: UInt32 = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // Subchunk1Size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })  // AudioFormat PCM = 1
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var result = header
        result.append(pcmData)
        return result
    }

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
    /// Этап 2: fail-closed без force-unwrap — nil + лог вместо краша.
    static func pcm16Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }

        var data = Data(count: frames * 2)
        var conversionOK = false
        data.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
            guard let dst = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frames {
                let clamped = max(-1.0, min(1.0, src[i]))
                dst[i] = Int16(clamped * Float(Int16.max))
            }
            conversionOK = true
        }
        guard conversionOK else {
            NSLog("[SingAR] WAVWriter.pcm16Data: destination baseAddress nil (frames=%d)", frames)
            return nil
        }
        return data
    }

    private static func convertToInt16(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false
        ) else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        guard let dst = out.int16ChannelData?[0] else {
            NSLog("[SingAR] WAVWriter.convertToInt16: int16ChannelData nil")
            return nil
        }
        for i in 0..<frames {
            let clamped = max(-1.0, min(1.0, src[i]))
            dst[i] = Int16(clamped * Float(Int16.max))
        }
        return out
    }
}
