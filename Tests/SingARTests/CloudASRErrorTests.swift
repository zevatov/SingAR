import XCTest
@testable import SingAR

/// Gate 1.7: typed cloud ASR error model — pure classifier tests, no network.
final class CloudASRErrorTests: XCTestCase {

    // MARK: HTTP status classifier

    func testHTTP401MapsToInvalidKey() {
        XCTAssertEqual(CloudASRError.from(status: 401), .invalidKey(status: 401))
    }

    func testHTTP403MapsToInvalidKey() {
        XCTAssertEqual(CloudASRError.from(status: 403), .invalidKey(status: 403))
    }

    func testHTTP429MapsToRateLimited() {
        XCTAssertEqual(CloudASRError.from(status: 429), .rateLimited)
    }

    func testHTTP5xxMapsToServerError() {
        XCTAssertEqual(CloudASRError.from(status: 500), .serverError(status: 500))
        XCTAssertEqual(CloudASRError.from(status: 503), .serverError(status: 503))
    }

    func testUnexpectedStatusMapsToServerError() {
        // e.g. legacy 404 branch: model renamed — still typed, not dropped.
        XCTAssertEqual(CloudASRError.from(status: 404), .serverError(status: 404))
    }

    // MARK: URLError classifier

    func testTimedOutMapsToTimeout() {
        let err = CloudASRError.from(URLError(.timedOut) as Error)
        XCTAssertEqual(err, .timeout)
    }

    func testCancelledMapsToCancelled() {
        let err = CloudASRError.from(URLError(.cancelled) as Error)
        XCTAssertEqual(err, .cancelled)
    }

    func testGenericURLErrorMapsToNetwork() {
        let underlying = URLError(.notConnectedToInternet)
        let err = CloudASRError.from(underlying as Error)
        XCTAssertEqual(err, .network(underlying: underlying))
    }

    func testNonURLErrorMapsToNetwork() {
        let err = CloudASRError.from(CocoaError(.fileNoSuchFile) as Error)
        guard case .network = err else {
            return XCTFail("expected .network, got \(err)")
        }
    }

    // MARK: UI surfacing contract

    func testDedicatedMessageShownForUserActionableErrors() {
        XCTAssertTrue(CloudASRError.invalidKey(status: 401).showsDedicatedMessage)
        XCTAssertTrue(CloudASRError.rateLimited.showsDedicatedMessage)
        XCTAssertTrue(CloudASRError.network(underlying: URLError(.notConnectedToInternet)).showsDedicatedMessage)
    }

    func testGenericErrorsKeepDefaultLabel() {
        XCTAssertFalse(CloudASRError.timeout.showsDedicatedMessage)
        XCTAssertFalse(CloudASRError.cancelled.showsDedicatedMessage)
        XCTAssertFalse(CloudASRError.emptySpeech.showsDedicatedMessage)
        XCTAssertFalse(CloudASRError.serverError(status: 500).showsDedicatedMessage)
        XCTAssertFalse(CloudASRError.missingKey.showsDedicatedMessage)
    }

    // MARK: Gate 2.5 polish typed-error contract (pure classifier, no network)

    func testPolishEmptyInputMapsToEmptySpeech() {
        // polishResult("") must fail typed, never succeed with empty text.
        let exp = expectation(description: "polishResult empty input")
        Task {
            let result = await CloudASR().polishResult(text: "")
            XCTAssertEqual(result, .failure(.emptySpeech))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testPolishEmptyInputMapsToEmptySpeechStaysSilentInUI() {
        // The empty-input failure must be silent in UI (no dedicated capsule),
        // keeping the Gate 0 quiet-fallback contract.
        XCTAssertTrue(CloudASRError.emptySpeech.showsDedicatedMessage == false)
    }

    func testUserMessagesAreNonEmpty() {
        let all: [CloudASRError] = [
            .invalidKey(status: 401), .rateLimited, .serverError(status: 500),
            .network(underlying: URLError(.notConnectedToInternet)),
            .timeout, .cancelled, .emptySpeech, .missingKey
        ]
        for e in all {
            XCTAssertFalse(e.userMessage.isEmpty, "empty message for \(e)")
        }
    }
}
