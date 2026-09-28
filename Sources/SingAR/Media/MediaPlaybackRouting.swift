import Foundation
import Darwin

/// Pure pause/resume routing. Probes stay in `MediaController`; this type only
/// decides which source may receive Pause or Play so a unit test never needs
/// CoreAudio, MediaRemote, or AppleScript.
///
/// Invariant: a source that was not playing at session start is never resumed.
/// CoreAudio / IOKit noise without a Now Playing client is not a MediaRemote
/// pause and must not grow a Play on the way out.
enum MediaPlaybackRouting {

    /// Addressable player. `none` means "do not touch media".
    enum Source: String, Equatable {
        case music = "Music"
        case spotify = "Spotify"
        case mediaRemote = "MediaRemote"
        case none = "none"
    }

    /// What each probe reported at the moment the decision is made.
    /// `coreAudio` / `iokitVideo` are evidence of sound or video, not an
    /// address we can Play back into.
    struct Snapshot: Equatable {
        var musicPlaying: Bool
        var spotifyPlaying: Bool
        var mediaRemotePlaying: Bool
        var coreAudioPlaying: Bool
        var iokitVideoPlaying: Bool

        static let silent = Snapshot(
            musicPlaying: false,
            spotifyPlaying: false,
            mediaRemotePlaying: false,
            coreAudioPlaying: false,
            iokitVideoPlaying: false
        )
    }

    /// Pause targets for one session start. MediaRemote is included only when
    /// Now Playing itself reports playback — never because CoreAudio heard
    /// something else.
    struct PausePlan: Equatable {
        var music: Bool
        var spotify: Bool
        var mediaRemote: Bool
        /// CoreAudio PID heard while this plan was built. Telemetry only:
        /// resume never addresses a PID, and a mismatch is log-only.
        var pausedPID: pid_t? = nil

        static let none = PausePlan(music: false, spotify: false, mediaRemote: false)

        var touchesAnything: Bool { music || spotify || mediaRemote }

        /// Source named in the pause log. Dedicated apps win over Now Playing
        /// when both were actually playing; the plan still pauses every set flag.
        var pausedSource: Source {
            if music { return .music }
            if spotify { return .spotify }
            if mediaRemote { return .mediaRemote }
            return .none
        }
    }

    /// Resume targets. Must be the pause plan of the same session; a nil plan
    /// (media was already paused before dictation) resumes nothing.
    struct ResumePlan: Equatable {
        var music: Bool
        var spotify: Bool
        var mediaRemote: Bool

        static let none = ResumePlan(music: false, spotify: false, mediaRemote: false)

        var resumeSource: Source {
            if music { return .music }
            if spotify { return .spotify }
            if mediaRemote { return .mediaRemote }
            return .none
        }

        var sendsPlay: Bool { music || spotify || mediaRemote }
    }

    /// One Play attempt and its observed result. `confirmed` is the probe of
    /// the same source ~0.4s later, not the fact that the command was sent.
    struct ResumeAttempt: Equatable {
        var source: Source
        var sent: Bool
        var confirmed: Bool
    }

    static func pausePlan(from snapshot: Snapshot, pausedPID: pid_t? = nil) -> PausePlan {
        PausePlan(
            music: snapshot.musicPlaying,
            spotify: snapshot.spotifyPlaying,
            mediaRemote: snapshot.mediaRemotePlaying,
            pausedPID: pausedPID
        )
    }

    /// True only when both PIDs are known and differ.
    /// Callers may log `pid_mismatch`; they must not retarget Play.
    static func coreAudioPIDMismatch(pausedPID: pid_t?, currentPID: pid_t?) -> Bool {
        guard let pausedPID, let currentPID else { return false }
        return pausedPID != currentPID
    }

    /// `paused == nil` is the "already paused before start" branch: Play is
    /// forbidden even if some probe is hot by the time dictation ends.
    static func resumePlan(paused: PausePlan?) -> ResumePlan {
        guard let paused else { return .none }
        return ResumePlan(
            music: paused.music,
            spotify: paused.spotify,
            mediaRemote: paused.mediaRemote
        )
    }

    /// After the first Play, one repeat is allowed only for the same source
    /// and only when that source is still not playing. A second miss stops.
    static func shouldRepeatPlay(attempt: Int, confirmed: Bool) -> Bool {
        attempt == 1 && !confirmed
    }

    static func isSourcePlaying(_ source: Source, snapshot: Snapshot) -> Bool {
        switch source {
        case .music: return snapshot.musicPlaying
        case .spotify: return snapshot.spotifyPlaying
        case .mediaRemote: return snapshot.mediaRemotePlaying
        case .none: return false
        }
    }
}
