import XCTest
import AVFoundation
@testable import SingAR

/// Этап 2 (стабильность ядра диктовки): offline-тесты без сети/микрофона/Keychain/AX.
/// Покрывают pure-seams, введённые в Этапе 2:
/// VAD once-per-segment + clamp, GeminiLive pre-connect/reconnect/drain,
/// SpeechEngine early-frames, DictationController split-flags.
/// Существующие 161 тест Этапов 0–1 не тронуты.
final class Stage2StabilityTests: XCTestCase {

    private let sampleRate: Double = 16000
    private let framesPerBuffer = AVAudioFrameCount(1600)

    private func silenceBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer)!
        buffer.frameLength = framesPerBuffer
        return buffer
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

    // MARK: VAD — конец речи once-per-segment (не повторяется за долгую паузу)

    func testEndOfSpeechFiresOncePerLongPause() {
        let vad = VoiceActivityDetector()
        var count = 0
        vad.onEndOfSpeech = { count += 1 }
        vad.feed(loudBuffer())
        for _ in 0..<30 { vad.feed(silenceBuffer()) } // 3с тишины
        XCTAssertEqual(count, 1, "долгая пауза — ровно один конец речи на сегмент")
        XCTAssertTrue(vad.hasSpoken, "hasSpoken не сбрасывается паузой (только reset)")
    }

    func testEndOfSpeechRearmsAfterNewSpeech() {
        let vad = VoiceActivityDetector()
        var count = 0
        vad.onEndOfSpeech = { count += 1 }
        vad.feed(loudBuffer())
        for _ in 0..<7 { vad.feed(silenceBuffer()) }
        XCTAssertEqual(count, 1)
        vad.feed(loudBuffer()) // новый сегмент — one-shot взводится заново
        for _ in 0..<7 { vad.feed(silenceBuffer()) }
        XCTAssertEqual(count, 2, "новая речь после паузы — второй конец речи")
    }

    func testLevelClampedToUnitRange() {
        let vad = VoiceActivityDetector()
        var levels: [Float] = []
        vad.onLevel = { levels.append($0) }
        vad.feed(loudBuffer())
        XCTAssertEqual(levels.count, 1)
        XCTAssertGreaterThanOrEqual(levels[0], 0)
        XCTAssertLessThanOrEqual(levels[0], 1, "уровень всегда 0...1 (clamp)")
    }

    // MARK: GeminiLive — pre-connect очередь DROP-OLDEST + счётчик

    func testPreConnectPlanBelowCapKeepsAll() {
        let plan = GeminiLiveEngine.preConnectPlan(incoming: 50, alreadyQueued: 100)
        XCTAssertEqual(plan.kept, 50)
        XCTAssertEqual(plan.dropped, 0)
    }

    func testPreConnectPlanOverflowDropsOldestWithCount() {
        let plan = GeminiLiveEngine.preConnectPlan(incoming: 60, alreadyQueued: 180)
        XCTAssertEqual(plan.kept, 20, "при cap=200 из 240 выживают 20 новых")
        XCTAssertEqual(plan.dropped, 40, "счётчик дропа = overflow")
    }

    func testFlushBurstCapEqualsQueueCap() {
        XCTAssertEqual(GeminiLiveEngine.flushBurstCap, GeminiLiveEngine.maxPendingChunks,
                       "burst сброса ограничен тем же cap — без unbounded-цикла")
    }

    // MARK: GeminiLive — reconnect только на транспортабельных + бэкофф

    func testShouldReconnectOnlyTransportErrors() {
        XCTAssertTrue(GeminiLiveEngine.shouldReconnect(error: .network(underlying: URLError(.notConnectedToInternet)), attempt: 0))
        XCTAssertTrue(GeminiLiveEngine.shouldReconnect(error: .timeout, attempt: 0))
        XCTAssertTrue(GeminiLiveEngine.shouldReconnect(error: .serverError(status: 500), attempt: 1))
        XCTAssertFalse(GeminiLiveEngine.shouldReconnect(error: .invalidKey(status: 401), attempt: 0),
                       "auth-ошибка — явный реконнект запрещён (не долбить сервер)")
        XCTAssertFalse(GeminiLiveEngine.shouldReconnect(error: .missingKey, attempt: 0))
        XCTAssertFalse(GeminiLiveEngine.shouldReconnect(error: .cancelled, attempt: 0),
                       "Esc-отмена — никакого реконнекта")
        XCTAssertFalse(GeminiLiveEngine.shouldReconnect(error: .network(underlying: URLError(.notConnectedToInternet)), attempt: 2),
                       "попытки исчерпаны — стоп")
    }

    func testReconnectBackoffGrows() {
        XCTAssertEqual(GeminiLiveEngine.reconnectBackoffMs(attempt: 0), 500)
        XCTAssertEqual(GeminiLiveEngine.reconnectBackoffMs(attempt: 1), 1_000)
        XCTAssertEqual(GeminiLiveEngine.reconnectBackoffMs(attempt: 5), 2_000)
    }

    // MARK: GeminiLive — drain без соединения = 0 (убрать всегда +850мс)

    func testFinalizeDrainZeroWithoutConnection() {
        XCTAssertEqual(GeminiLiveEngine.finalizeDrainMs(connected: false), 0,
                       "без соединения — ранний выход, никакого drain")
        XCTAssertEqual(GeminiLiveEngine.finalizeDrainMs(connected: true), 850)
    }

    // MARK: SpeechEngine — ранние кадры не теряются

    func testEarlyFramePlanBelowCapKeepsAll() {
        let plan = SpeechEngine.earlyFramePlan(incoming: 10, alreadyBuffered: 5)
        XCTAssertEqual(plan.kept, 10)
        XCTAssertEqual(plan.droppedOldest, 0)
    }

    func testEarlyFramePlanOverflowDropsOldestBounded() {
        let plan = SpeechEngine.earlyFramePlan(incoming: 10, alreadyBuffered: 30)
        XCTAssertEqual(plan.kept, 2, "при cap=32 из 40 выживают 2 новых")
        XCTAssertEqual(plan.droppedOldest, 8)
    }

    func testEarlyFrameCapIsPositiveBounded() {
        XCTAssertGreaterThan(SpeechEngine.maxEarlyFrames, 0)
        XCTAssertLessThanOrEqual(SpeechEngine.maxEarlyFrames, 64,
                                 "ранний буфер ограничен — unbounded-рост запрещён")
    }

    // MARK: Controller — разделение флагов кормления и подсказок

    func testResolveLiveFlagsParityWithLivePartials() {
        let on = DictationController.resolveLiveFlags(livePartials: true)
        XCTAssertTrue(on.feedsEngines)
        XCTAssertTrue(on.showsLiveHints)
        let off = DictationController.resolveLiveFlags(livePartials: false)
        XCTAssertFalse(off.feedsEngines)
        XCTAssertFalse(off.showsLiveHints)
    }
}
