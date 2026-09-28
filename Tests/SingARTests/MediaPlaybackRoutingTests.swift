import XCTest
@testable import SingAR

/// Bug A: who may receive Pause/Play. Pure routing only — no CoreAudio,
/// MediaRemote, AppleScript, or a running player.
final class MediaPlaybackRoutingTests: XCTestCase {

    func testCoreAudioAloneDoesNotPauseMediaRemote() {
        var snap = MediaPlaybackRouting.Snapshot.silent
        snap.coreAudioPlaying = true
        snap.iokitVideoPlaying = true
        let plan = MediaPlaybackRouting.pausePlan(from: snap)
        XCTAssertEqual(plan, .none)
        XCTAssertEqual(plan.pausedSource, .none)
        XCTAssertFalse(plan.touchesAnything)
    }

    func testNowPlayingPausesOnlyMediaRemote() {
        var snap = MediaPlaybackRouting.Snapshot.silent
        snap.mediaRemotePlaying = true
        snap.coreAudioPlaying = true
        let plan = MediaPlaybackRouting.pausePlan(from: snap)
        XCTAssertEqual(plan, MediaPlaybackRouting.PausePlan(music: false, spotify: false, mediaRemote: true))
        XCTAssertEqual(plan.pausedSource, .mediaRemote)
    }

    func testMusicAndSpotifyAreAddressedSeparately() {
        var music = MediaPlaybackRouting.Snapshot.silent
        music.musicPlaying = true
        let musicPlan = MediaPlaybackRouting.pausePlan(from: music)
        XCTAssertEqual(musicPlan.pausedSource, .music)
        XCTAssertFalse(musicPlan.mediaRemote)

        var spotify = MediaPlaybackRouting.Snapshot.silent
        spotify.spotifyPlaying = true
        let spotifyPlan = MediaPlaybackRouting.pausePlan(from: spotify)
        XCTAssertEqual(spotifyPlan.pausedSource, .spotify)
        XCTAssertFalse(spotifyPlan.mediaRemote)
    }

    func testResumeGoesOnlyToThePausedSource() {
        let paused = MediaPlaybackRouting.PausePlan(music: false, spotify: true, mediaRemote: false)
        let resume = MediaPlaybackRouting.resumePlan(paused: paused)
        XCTAssertEqual(resume.resumeSource, .spotify)
        XCTAssertTrue(resume.spotify)
        XCTAssertFalse(resume.music)
        XCTAssertFalse(resume.mediaRemote)
    }

    func testAlreadyPausedSessionSendsNoPlay() {
        let resume = MediaPlaybackRouting.resumePlan(paused: nil)
        XCTAssertEqual(resume, .none)
        XCTAssertFalse(resume.sendsPlay)
        XCTAssertEqual(resume.resumeSource, .none)
    }

    func testSilentSnapshotResumesNothing() {
        let paused = MediaPlaybackRouting.pausePlan(from: .silent)
        let resume = MediaPlaybackRouting.resumePlan(paused: paused)
        XCTAssertFalse(resume.sendsPlay)
    }

    func testPlayRepeatsOnceOnlyWhenUnconfirmed() {
        XCTAssertTrue(MediaPlaybackRouting.shouldRepeatPlay(attempt: 1, confirmed: false))
        XCTAssertFalse(MediaPlaybackRouting.shouldRepeatPlay(attempt: 1, confirmed: true))
        XCTAssertFalse(MediaPlaybackRouting.shouldRepeatPlay(attempt: 2, confirmed: false))
    }

    func testConfirmationReadsTheSameSource() {
        var snap = MediaPlaybackRouting.Snapshot.silent
        snap.musicPlaying = true
        XCTAssertTrue(MediaPlaybackRouting.isSourcePlaying(.music, snapshot: snap))
        XCTAssertFalse(MediaPlaybackRouting.isSourcePlaying(.mediaRemote, snapshot: snap))
        XCTAssertFalse(MediaPlaybackRouting.isSourcePlaying(.none, snapshot: snap))
    }

    func testPausePlanStoresPIDAndDefaultsToNil() {
        var snap = MediaPlaybackRouting.Snapshot.silent
        snap.mediaRemotePlaying = true
        let stored = MediaPlaybackRouting.pausePlan(from: snap, pausedPID: 12345)
        XCTAssertEqual(stored.pausedPID, 12345)
        XCTAssertEqual(stored.pausedSource, .mediaRemote)
        XCTAssertTrue(stored.mediaRemote)
        XCTAssertFalse(stored.music)
        XCTAssertFalse(stored.spotify)

        let omitted = MediaPlaybackRouting.pausePlan(from: snap)
        XCTAssertNil(omitted.pausedPID)
        XCTAssertEqual(omitted, MediaPlaybackRouting.PausePlan(music: false, spotify: false, mediaRemote: true))

        let memberwise = MediaPlaybackRouting.PausePlan(music: true, spotify: false, mediaRemote: false)
        XCTAssertNil(memberwise.pausedPID)
        XCTAssertEqual(memberwise.pausedSource, .music)
    }

    func testNilPausePlanSendsNoPlay() {
        let resume = MediaPlaybackRouting.resumePlan(paused: nil)
        XCTAssertEqual(resume, .none)
        XCTAssertFalse(resume.sendsPlay)
        XCTAssertEqual(resume.resumeSource, .none)
        XCTAssertFalse(resume.music)
        XCTAssertFalse(resume.spotify)
        XCTAssertFalse(resume.mediaRemote)
    }

    func testResumeStaysOnThePausedSourceWhenPIDDiffers() {
        let spotify = MediaPlaybackRouting.PausePlan(music: false, spotify: true, mediaRemote: false, pausedPID: 42)
        let spotifyResume = MediaPlaybackRouting.resumePlan(paused: spotify)
        XCTAssertEqual(spotifyResume.resumeSource, .spotify)
        XCTAssertTrue(spotifyResume.sendsPlay)
        XCTAssertTrue(spotifyResume.spotify)
        XCTAssertFalse(spotifyResume.music)
        XCTAssertFalse(spotifyResume.mediaRemote)
        XCTAssertTrue(MediaPlaybackRouting.coreAudioPIDMismatch(pausedPID: 42, currentPID: 99))
        XCTAssertEqual(spotifyResume.resumeSource, .spotify)

        var musicSnap = MediaPlaybackRouting.Snapshot.silent
        musicSnap.musicPlaying = true
        let musicResume = MediaPlaybackRouting.resumePlan(
            paused: MediaPlaybackRouting.pausePlan(from: musicSnap, pausedPID: 7)
        )
        XCTAssertEqual(musicResume.resumeSource, .music)
        XCTAssertTrue(musicResume.music)
        XCTAssertFalse(musicResume.spotify)
        XCTAssertFalse(musicResume.mediaRemote)

        var nowPlaying = MediaPlaybackRouting.Snapshot.silent
        nowPlaying.mediaRemotePlaying = true
        let mediaRemoteResume = MediaPlaybackRouting.resumePlan(
            paused: MediaPlaybackRouting.pausePlan(from: nowPlaying, pausedPID: 8)
        )
        XCTAssertEqual(mediaRemoteResume.resumeSource, .mediaRemote)
        XCTAssertTrue(mediaRemoteResume.mediaRemote)
        XCTAssertFalse(mediaRemoteResume.music)
        XCTAssertFalse(mediaRemoteResume.spotify)

        XCTAssertFalse(MediaPlaybackRouting.coreAudioPIDMismatch(pausedPID: 42, currentPID: 42))
        XCTAssertFalse(MediaPlaybackRouting.coreAudioPIDMismatch(pausedPID: 42, currentPID: nil))
        XCTAssertFalse(MediaPlaybackRouting.coreAudioPIDMismatch(pausedPID: nil, currentPID: 99))

        var coreOnly = MediaPlaybackRouting.Snapshot.silent
        coreOnly.coreAudioPlaying = true
        let corePlan = MediaPlaybackRouting.pausePlan(from: coreOnly, pausedPID: 55)
        XCTAssertEqual(corePlan.pausedPID, 55)
        XCTAssertFalse(corePlan.touchesAnything)
        XCTAssertEqual(corePlan.pausedSource, .none)
        let coreResume = MediaPlaybackRouting.resumePlan(paused: corePlan)
        XCTAssertEqual(coreResume, .none)
        XCTAssertFalse(coreResume.sendsPlay)
        XCTAssertEqual(coreResume.resumeSource, .none)
    }
}

/// Bug C: an empty Whisper result must not erase a usable live/local transcript.
final class WhisperFallbackTests: XCTestCase {

    func testEmptyCloudKeepsLiveText() {
        XCTAssertEqual(
            DictationController.whisperFallbackText(liveOrLocal: "черновик", cloudText: ""),
            "черновик"
        )
    }

    func testWhitespaceCloudKeepsLocalTranscript() {
        XCTAssertEqual(
            DictationController.whisperFallbackText(liveOrLocal: "локальный", cloudText: " \n"),
            "локальный"
        )
    }

    func testNonEmptyCloudReplacesFallback() {
        XCTAssertEqual(
            DictationController.whisperFallbackText(liveOrLocal: "черновик", cloudText: "точный"),
            "точный"
        )
    }

    func testBothEmptyStaysEmpty() {
        XCTAssertEqual(
            DictationController.whisperFallbackText(liveOrLocal: "  ", cloudText: ""),
            ""
        )
        XCTAssertEqual(DictationController.emptyRecognitionStatus, "Ничего не распознано")
    }

    func testPolishTimeoutAndServerErrorSurfaceUnpolishedStatus() {
        XCTAssertTrue(DictationController.polishNeedsUnpolishedStatus(.timeout))
        XCTAssertTrue(DictationController.polishNeedsUnpolishedStatus(.serverError(status: 503)))
        XCTAssertFalse(DictationController.polishNeedsUnpolishedStatus(.invalidKey(status: 401)))
        XCTAssertFalse(DictationController.polishNeedsUnpolishedStatus(nil))
        XCTAssertEqual(DictationController.unpolishedInsertStatus, "Текст без правки")
    }
}
