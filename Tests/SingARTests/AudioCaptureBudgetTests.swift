import XCTest
import AVFoundation
@testable import SingAR

/// PRE-DMG-FIX-CAP offline regression for the local capture budget:
/// the REAL production helpers (`AudioRecorder.capturePlan`,
/// `AudioRecorder.trimmedPrefixCopy`,
/// `DictationController.truncatedSnapshotSkipsCloud`) called with synthetic
/// PCM buffers — no microphone, no network, no engine, no CGEvent.
final class AudioCaptureBudgetTests: XCTestCase {

    private var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    private func makeBuffer(frames: Int, value: Float = 0.5) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData {
            for i in 0..<frames { data[0][i] = value }
        }
        return buffer
    }

    // MARK: capturePlan — the single production decision per tap buffer

    // Below cap: everything is kept and delivered, edge not crossed.
    func testCapturePlanBelowCapAdmitsFully() {
        let cap = AudioRecorder.maxCapturedFrames
        let plan = AudioRecorder.capturePlan(capturedFrames: cap - 1_000, incomingFrames: 500)
        XCTAssertEqual(plan, AudioRecorder.CapturePlan(keepFrames: 500, deliverFrames: 500, limitEdgeCrossed: false))
    }

    // Exactly filling to cap: still the normal path, no edge.
    func testCapturePlanExactFillDoesNotCrossEdge() {
        let cap = AudioRecorder.maxCapturedFrames
        let plan = AudioRecorder.capturePlan(capturedFrames: cap - 400, incomingFrames: 400)
        XCTAssertEqual(plan, AudioRecorder.CapturePlan(keepFrames: 400, deliverFrames: 400, limitEdgeCrossed: false))
    }

    // Boundary buffer: trim frame-exactly to the remaining budget, deliver the
    // same trimmed prefix, report the edge exactly once for this buffer.
    func testCapturePlanBoundaryTrimsFrameExactAndCrossesEdge() {
        let cap = AudioRecorder.maxCapturedFrames
        let plan = AudioRecorder.capturePlan(capturedFrames: cap - 300, incomingFrames: 1_000)
        XCTAssertEqual(plan, AudioRecorder.CapturePlan(keepFrames: 300, deliverFrames: 300, limitEdgeCrossed: true))
    }

    // Past cap: nothing is kept AND nothing is fed to the live path — the
    // controller's auto-finalize owns the session from the edge.
    func testCapturePlanPastCapKeepsAndFeedsNothing() {
        let cap = AudioRecorder.maxCapturedFrames
        let plan = AudioRecorder.capturePlan(capturedFrames: cap, incomingFrames: 1_000)
        XCTAssertEqual(plan, AudioRecorder.CapturePlan(keepFrames: 0, deliverFrames: 0, limitEdgeCrossed: true))
    }

    // Sequential buffer stream simulating the REAL production lifecycle:
    // feed → edge → the controller's one-shot auto-finalize stops the tap
    // (audio.stop()), so NO further buffers ever reach the plan. Invariants:
    // exactly one edge, snapshot and live feed both end at exactly cap frames.
    func testSequentialBuffersAdmitExactlyCapAndStopFeeding() {
        let cap = AudioRecorder.maxCapturedFrames
        let bufferSizes = [4_096, 4_096, 4_096, 8_192, 1_024]
        var captured = 0
        var deliveredTotal = 0
        var edges = 0
        var index = 0
        while index < 500_000 { // far more buffers than needed to pass the cap
            let incoming = bufferSizes[index % bufferSizes.count]
            let plan = AudioRecorder.capturePlan(capturedFrames: captured, incomingFrames: incoming)
            captured += plan.keepFrames
            deliveredTotal += plan.deliverFrames
            if plan.limitEdgeCrossed {
                edges += 1
                // Production parity: the auto-finalize handler (main queue)
                // triggers stopDictation → audio.stop() at this very edge;
                // the tap is removed, so feeding stops here. deliverFrames
                // must equal keepFrames (the trimmed prefix, not the full
                // oversized buffer) so nothing beyond the cap is ever fed.
                XCTAssertEqual(plan.deliverFrames, plan.keepFrames,
                               "live feed must receive only the trimmed in-budget prefix")
                break
            }
            index += 1
        }
        XCTAssertEqual(edges, 1, "one stream must cross the edge exactly once (one-shot callback)")
        XCTAssertEqual(captured, cap, "snapshot must be bounded to exactly the cap frames")
        XCTAssertEqual(deliveredTotal, cap, "live feed must receive exactly cap frames, nothing beyond")
    }

    // MARK: trimmedPrefixCopy — boundary buffer handling

    // The trimmed copy owns its storage: mutating the source must not leak
    // into the snapshot.
    func testTrimmedPrefixCopyOwnsStorageAndMatchesFrames() {
        let source = makeBuffer(frames: 1_000, value: 0.25)
        guard let copy = AudioRecorder.trimmedPrefixCopy(source, frames: 300) else {
            return XCTFail("trim must succeed inside 1...frameLength")
        }
        XCTAssertEqual(Int(copy.frameLength), 300)
        XCTAssertEqual(copy.format.sampleRate, format.sampleRate)
        // Snapshot immutability: overwrite the source AFTER copying.
        if let data = source.floatChannelData {
            for i in 0..<1_000 { data[0][i] = -1.0 }
        }
        let copied = Array(UnsafeBufferPointer(start: copy.floatChannelData![0], count: 300))
        XCTAssertTrue(copied.allSatisfy { $0 == 0.25 }, "copy must own its storage — no aliasing")
    }

    // Out-of-range trim requests are refused (fail-closed).
    func testTrimmedPrefixCopyRefusesOutOfRange() {
        let source = makeBuffer(frames: 100)
        XCTAssertNil(AudioRecorder.trimmedPrefixCopy(source, frames: 0))
        XCTAssertNil(AudioRecorder.trimmedPrefixCopy(source, frames: 101))
    }

    // MARK: truncated-snapshot guard — full live text beats truncated cloud

    func testTruncatedSnapshotSkipsCloudPasses() {
        XCTAssertTrue(
            DictationController.truncatedSnapshotSkipsCloud(snapshotTruncated: true),
            "truncated snapshot must not feed the cloud passes (no destructive replacement)"
        )
        XCTAssertFalse(
            DictationController.truncatedSnapshotSkipsCloud(snapshotTruncated: false),
            "a complete snapshot keeps the normal cloud path"
        )
    }
}
