import XCTest
@testable import SingAR

final class SoundFeedbackTests: XCTestCase {

    func testPlaySoundEffectsDefaultsToTrue() {
        let settings = AppSettings.shared
        XCTAssertTrue(settings.playSoundEffects)
    }

    func testSoundFeedbackRespectsMute() {
        let settings = AppSettings.shared
        let original = settings.playSoundEffects
        defer { settings.playSoundEffects = original }

        settings.playSoundEffects = false
        // Calling start and stop must not crash or throw when muted
        SoundFeedback.start()
        SoundFeedback.stop()

        settings.playSoundEffects = true
        SoundFeedback.start()
        SoundFeedback.stop()
    }
}
