import XCTest
import AVFoundation
@testable import SingAR

/// Gate 0.6: корректность WAV header и размера на синтетических сэмплах.
final class WAVWriterTests: XCTestCase {

    // MARK: Helpers

    private func makeBuffer(frames: Int, sampleRate: Double = 16000, fill: ((Int, UnsafeMutablePointer<Float>) -> Void)? = nil) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let fill {
            fill(frames, buffer.floatChannelData![0])
        }
        return buffer
    }

    private func leUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) |
        (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func leUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[data.startIndex + offset]) |
        (UInt32(data[data.startIndex + offset + 1]) << 8) |
        (UInt32(data[data.startIndex + offset + 2]) << 16) |
        (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    private func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
        String(decoding: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count)), as: UTF8.self)
    }

    // MARK: Header & size

    func testWavHeaderFields() throws {
        let frames = 1600
        let buffer = makeBuffer(frames: frames) { n, ch in
            for i in 0..<n { ch[i] = sin(Float(i) * 2.0 * .pi * 440.0 / 16000.0) * 0.5 }
        }
        let wav = try XCTUnwrap(WAVWriter.wavData(from: [buffer]))

        XCTAssertEqual(ascii(wav, 0, 4), "RIFF")
        XCTAssertEqual(leUInt32(wav, 4), UInt32(36 + frames * 2))       // chunkSize
        XCTAssertEqual(ascii(wav, 8, 4), "WAVE")
        XCTAssertEqual(ascii(wav, 12, 4), "fmt ")
        XCTAssertEqual(leUInt32(wav, 16), 16)                            // Subchunk1Size
        XCTAssertEqual(leUInt16(wav, 20), 1)                             // AudioFormat = PCM
        XCTAssertEqual(leUInt16(wav, 22), 1)                             // channels = mono
        XCTAssertEqual(leUInt32(wav, 24), 16000)                         // sampleRate
        XCTAssertEqual(leUInt32(wav, 28), 16000 * 2)                     // byteRate
        XCTAssertEqual(leUInt16(wav, 32), 2)                             // blockAlign
        XCTAssertEqual(leUInt16(wav, 34), 16)                            // bitsPerSample
        XCTAssertEqual(ascii(wav, 36, 4), "data")
        XCTAssertEqual(leUInt32(wav, 40), UInt32(frames * 2))            // dataSize
        XCTAssertEqual(wav.count, 44 + frames * 2)
    }

    func testWavSizeForMultipleBuffers() {
        let b1 = makeBuffer(frames: 800)
        let b2 = makeBuffer(frames: 400)
        let wav = WAVWriter.wavData(from: [b1, b2])
        XCTAssertNotNil(wav)
        XCTAssertEqual(wav?.count, 44 + (800 + 400) * 2)
    }

    // MARK: Edge cases

    func testEmptyBufferListReturnsNil() {
        XCTAssertNil(WAVWriter.wavData(from: []))
    }

    func testZeroFrameBufferReturnsNil() {
        let buffer = makeBuffer(frames: 0)
        XCTAssertNil(WAVWriter.wavData(from: [buffer]))
    }

    func testClampingOfOutOfRangeSamples() {
        let frames = 8
        let buffer = makeBuffer(frames: frames) { n, ch in
            for i in 0..<n { ch[i] = i % 2 == 0 ? 2.0 : -2.0 }
        }
        let pcm = WAVWriter.pcm16Data(from: buffer)
        XCTAssertNotNil(pcm)
        XCTAssertEqual(pcm?.count, frames * 2)
        pcm!.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            XCTAssertEqual(samples[0], Int16.max)
            XCTAssertEqual(samples[1], -Int16.max)
        }
    }
}
