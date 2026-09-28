import XCTest
import AVFoundation
@testable import SingAR

/// Gate 0.6: silence/speech переходы VoiceActivityDetector на синтетических буферах.
final class VoiceActivityDetectorTests: XCTestCase {

    private let sampleRate: Double = 16000
    /// 100 мс буфер — как в реальном audio pipeline.
    private let framesPerBuffer = AVAudioFrameCount(1600)

    private func silenceBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)!
        buffer.frameLength = framesPerBuffer
        return buffer // нули = тишина
    }

    private func loudBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)!
        buffer.frameLength = framesPerBuffer
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(framesPerBuffer) {
            ch[i] = sin(Float(i) * 2.0 * .pi * 440.0 / Float(sampleRate)) * 0.3
        }
        return buffer
    }

    // MARK: Тишина без речи

    func testSilenceOnlySessionHasNoSpeech() {
        let vad = VoiceActivityDetector()
        var endOfSpeechCount = 0
        vad.onEndOfSpeech = { endOfSpeechCount += 1 }

        for _ in 0..<10 { vad.feed(silenceBuffer()) }

        XCTAssertFalse(vad.hasSpoken)
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertFalse(vad.isFeeding)
        XCTAssertEqual(endOfSpeechCount, 0)
    }

    // MARK: Речь и hangover

    func testLoudBufferMarksSpeaking() {
        let vad = VoiceActivityDetector()
        vad.feed(loudBuffer())
        XCTAssertTrue(vad.isSpeaking)
        XCTAssertTrue(vad.hasSpoken)
    }

    func testHangoverKeepsSpeakingThroughShortPause() {
        let vad = VoiceActivityDetector()
        vad.feed(loudBuffer())
        // 0.1s и 0.2s тишины — hangover (0.3s) ещё держит isSpeaking.
        vad.feed(silenceBuffer())
        XCTAssertTrue(vad.isSpeaking)
        vad.feed(silenceBuffer())
        XCTAssertTrue(vad.isSpeaking)
        // 0.3s — hangover истёк, но включается grace tail → isFeeding true.
        vad.feed(silenceBuffer())
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertTrue(vad.isFeeding)
    }

    func testGraceTailExhaustsAfterSilence() {
        let vad = VoiceActivityDetector()
        vad.feed(loudBuffer())
        // 3 буфера: hangover истёк, grace (0.7s) стартовал и тикает.
        for _ in 0..<3 { vad.feed(silenceBuffer()) }
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertTrue(vad.isFeeding)
        // Ещё 0.7s тишины: grace исчерпан.
        for _ in 0..<7 { vad.feed(silenceBuffer()) }
        XCTAssertFalse(vad.isFeeding)
    }

    // MARK: End-of-speech

    func testEndOfSpeechFiresOnceAfterSustainedSilence() {
        let vad = VoiceActivityDetector()
        var endOfSpeechCount = 0
        vad.onEndOfSpeech = { endOfSpeechCount += 1 }

        vad.feed(loudBuffer())
        // 0.7s тишины (> 0.6s требуемых) — ровно один callback.
        for _ in 0..<7 { vad.feed(silenceBuffer()) }
        XCTAssertEqual(endOfSpeechCount, 1)
        // hasSpoken не сбрасывается end-of-speech (см. комментарий в проде).
        XCTAssertTrue(vad.hasSpoken)
    }

    func testLevelCallbackDeliversClampedValues() {
        let vad = VoiceActivityDetector()
        var levels: [Float] = []
        vad.onLevel = { levels.append($0) }

        vad.feed(silenceBuffer())
        vad.feed(loudBuffer())

        XCTAssertEqual(levels.count, 2)
        XCTAssertGreaterThanOrEqual(levels[0], 0)
        XCTAssertLessThanOrEqual(levels[1], 1)
    }

    func testResetClearsState() {
        let vad = VoiceActivityDetector()
        vad.feed(loudBuffer())
        XCTAssertTrue(vad.hasSpoken)
        vad.reset()
        XCTAssertFalse(vad.hasSpoken)
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertFalse(vad.isFeeding)
        XCTAssertEqual(vad.diagnosticCapturedFrames, 0)
        XCTAssertEqual(vad.diagnosticSpeechFrames, 0)
    }

    func testDiagnosticCountsSpeechFramesWithoutChangingThreshold() {
        let vad = VoiceActivityDetector()
        XCTAssertEqual(vad.diagnosticSilenceThreshold, 0.012, accuracy: 0.000_001)
        let frames = Int(framesPerBuffer)
        vad.feed(loudBuffer())
        XCTAssertEqual(vad.diagnosticCapturedFrames, frames)
        XCTAssertEqual(vad.diagnosticSpeechFrames, frames)
        XCTAssertTrue(vad.hasSpoken)
        vad.feed(silenceBuffer())
        XCTAssertEqual(vad.diagnosticCapturedFrames, frames * 2)
        XCTAssertEqual(vad.diagnosticSpeechFrames, frames)
        XCTAssertEqual(vad.diagnosticSilenceThreshold, 0.012, accuracy: 0.000_001)
        XCTAssertTrue(vad.hasSpoken)
    }
}
