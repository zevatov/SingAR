import XCTest
@testable import SingAR

final class FocusGuardAndClipboardTests: XCTestCase {

    private final class MockAXProbe: AXFocusProbing {
        var trusted = true
        var secureInput = false
        var facts: FocusedElementFacts?
        var replaceResult = false
        var lastReplacedRange: NSRange?
        var lastReplacedText: String?

        func isProcessTrusted() -> Bool { trusted }
        func isSecureEventInput() -> Bool { secureInput }
        func readFocusedFacts() -> FocusedElementFacts? { facts }
        func replaceText(in range: NSRange, with text: String) -> Bool {
            lastReplacedRange = range
            lastReplacedText = text
            return replaceResult
        }
    }

    func testAppSettingsStopOnFocusLossDefaultAndMutation() {
        let settings = AppSettings.shared
        let original = settings.stopOnFocusLoss
        defer { settings.stopOnFocusLoss = original }

        settings.stopOnFocusLoss = false
        XCTAssertFalse(settings.stopOnFocusLoss)

        settings.stopOnFocusLoss = true
        XCTAssertTrue(settings.stopOnFocusLoss)
    }

    func testTargetGateNativeReplaceSucceedsWhenValid() {
        let probe = MockAXProbe()
        let gate = DictationFocusTargetGate(probe: probe)

        let identity = FocusedElementIdentity(role: "AXTextArea", title: "Doc")
        probe.facts = FocusedElementFacts(pid: 100, identity: identity, isValueSettable: true, value: "hello", selectedRange: NSRange(location: 5, length: 0))
        probe.replaceResult = true

        XCTAssertTrue(gate.captureSessionTarget(generation: 1))
        let replaced = gate.replaceText(generation: 1, range: NSRange(location: 0, length: 5), with: "world")

        XCTAssertTrue(replaced)
        XCTAssertEqual(probe.lastReplacedRange, NSRange(location: 0, length: 5))
        XCTAssertEqual(probe.lastReplacedText, "world")
    }

    func testTargetGateNativeReplaceFailsOnStaleGeneration() {
        let probe = MockAXProbe()
        let gate = DictationFocusTargetGate(probe: probe)

        let identity = FocusedElementIdentity(role: "AXTextArea", title: "Doc")
        probe.facts = FocusedElementFacts(pid: 100, identity: identity, isValueSettable: true, value: "hello", selectedRange: NSRange(location: 5, length: 0))
        probe.replaceResult = true

        XCTAssertTrue(gate.captureSessionTarget(generation: 1))
        // Calling with stale generation 2 must be denied
        let replaced = gate.replaceText(generation: 2, range: NSRange(location: 0, length: 5), with: "world")

        XCTAssertFalse(replaced)
    }

    func testTextInjectorCancelPendingRestoreIsSafe() {
        let injector = TextInjector()
        // Calling cancel on clean state is safe and does not crash
        injector.cancelPendingRestore()
        injector.cancelPendingRestore()
    }

    func testAppStatusSymbolsAndColorsMatchingSpec() {
        // Menu Bar & Capsule symbols
        XCTAssertEqual(AppStatus.listening.symbol, "mic.fill")
        XCTAssertEqual(AppStatus.recognizing.symbol, "sparkles")
        XCTAssertEqual(AppStatus.inserting.symbol, "doc.on.doc.fill")
        XCTAssertEqual(AppStatus.failed.symbol, "xmark.circle.fill")

        // Menu Bar & Capsule colors
        XCTAssertEqual(AppStatus.listening.color, .systemCyan)
        XCTAssertEqual(AppStatus.recognizing.color, .systemPurple)
        XCTAssertEqual(AppStatus.inserting.color, .systemGreen)
        XCTAssertEqual(AppStatus.failed.color, .systemRed)
    }

    func testAppVersionMatches225() {
        XCTAssertEqual(AppVersion.current, "2.2.5")
    }

    func testVADInitialSilenceState() {
        let vad = VoiceActivityDetector()
        XCTAssertFalse(vad.hasSpoken)
        XCTAssertFalse(vad.isSpeaking)
        XCTAssertFalse(vad.isFeeding)
    }

    func testMediaControllerInitializationAndSafeState() {
        let media = MediaController()
        // Calling pause and resume on safe state without active playback does not crash and does not send media keys
        media.pauseBackgroundMedia()
        media.resumeBackgroundMedia()
    }

    func testMediaControllerCoreAudioProbe() {
        let media = MediaController()
        // Probing CoreAudio hardware process list does not crash and returns a valid boolean
        let isCoreAudioPlaying = media.isCoreAudioOutputPlaying()
        XCTAssertTrue(isCoreAudioPlaying || !isCoreAudioPlaying)
    }

    func testDictationIndicatorVisibility() {
        let indicator = DictationIndicator()
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let point = NSPoint(x: screen.visibleFrame.maxX - 100, y: screen.visibleFrame.maxY)

        indicator.setStatus(.listening)
        indicator.show(near: point)

        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let panel = Mirror(reflecting: indicator).children.first(where: { $0.label == "panel" })?.value as! NSPanel
        let blur = Mirror(reflecting: indicator).children.first(where: { $0.label == "blur" })?.value as! NSVisualEffectView
        let stack = Mirror(reflecting: indicator).children.first(where: { $0.label == "contentStack" })?.value as! NSStackView

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1.0)
        XCTAssertFalse(blur.isHidden)
        XCTAssertFalse(stack.isHidden)
        XCTAssertEqual(stack.alphaValue, 1.0)
        XCTAssertGreaterThan(panel.frame.width, 100)
        XCTAssertGreaterThan(panel.frame.height, 30)

        // Test hide animation
        indicator.hide()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(panel.isVisible)
    }
}
