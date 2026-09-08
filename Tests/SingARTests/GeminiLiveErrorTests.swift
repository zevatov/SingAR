import XCTest
@testable import SingAR

/// Gate 2.4: live-path typed errors — no network, no keychain writes.
/// `GeminiLiveEngine.finalize()` keeps its `String` contract; these tests
/// pin the inspectable `lastLiveError()` surface added for the fallback path.
final class GeminiLiveErrorTests: XCTestCase {

    func testFreshEngineHasNoTypedError() {
        let engine = GeminiLiveEngine()
        XCTAssertNil(engine.lastLiveError())
    }

    func testCancelMapsToCancelled() {
        let engine = GeminiLiveEngine()
        engine.cancel()
        XCTAssertEqual(engine.lastLiveError(), .cancelled)
    }

    func testSecondCancelKeepsFirstTypedError() {
        let engine = GeminiLiveEngine()
        engine.cancel()
        engine.cancel()
        XCTAssertEqual(engine.lastLiveError(), .cancelled)
    }
}
