import XCTest
@testable import SingAR

final class WhisperIsolationTests: XCTestCase {

    func testMissingModelErrorProperties() {
        let err = CloudASRError.missingModel
        XCTAssertTrue(err.showsDedicatedMessage)
        XCTAssertEqual(err.userMessage, "Модель не загружена")
    }

    func testNoopASREngineContract() async {
        let noop = NoopASREngine()
        let result = await noop.finalize()
        XCTAssertEqual(result, "")
        noop.cancel()
    }

    func testLiveDraftDisplayModeDefaultsToHudOnly() {
        let settings = AppSettings.shared
        XCTAssertEqual(settings.liveDraftMode, .hudOnly)
    }
}
