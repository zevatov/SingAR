import Foundation
import AppKit
import CoreAudio
import IOKit.pwr_mgt

/// Pauses background media while dictating and intelligently resumes only if it was actually playing.
/// Supports native Apple Music, Spotify, browsers (YouTube/video in Safari, Chrome, Firefox), and Electron apps (Yandex Music).
/// Uses private MediaRemote.framework commands, CoreAudio hardware IO probes, and dedicated process-guarded AppleScript.
/// Completely avoids hardware media keys to prevent macOS Remote Control Daemon (rcd) from launching Apple Music.
final class MediaController {

    private let handle: UnsafeMutableRawPointer?

    private static let commands: [String: Int32] = [
        "kMRMediaRemoteCommandPlay": 0,
        "kMRMediaRemoteCommandPause": 1,
        "kMRMediaRemoteCommandTogglePlayPause": 2,
    ]

    /// Sources this session actually paused. `nil` until a pause plan is
    /// stored; resume of a nil plan sends no Play (media that was already
    /// paused before dictation must stay paused).
    private var pausedPlan: MediaPlaybackRouting.PausePlan?
    /// Bumped when a resume is consumed or a newer pause replaces it, so a
    /// late confirmation cannot send a second Play into a finished session.
    private var resumeEpoch = 0

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    // MARK: - Playback Detection

    /// Which probe reported playback. Names only — never a track title.
    enum PlaybackDetector: String {
        case coreAudio = "CoreAudio"
        case mediaRemote = "MediaRemote"
        case music = "Music"
        case spotify = "Spotify"
        case iokitVideo = "IOKitVideo"
        case none = "none"
    }

    /// Synchronous multi-layer check if ANY media (Spotify, Yandex Music, YouTube/Browser, Music.app)
    /// is actively outputting sound or video right now.
    func isAnyMediaPlaying() -> Bool {
        playingDetector() != .none
    }

    /// First probe that reports playback, in the same order as the pause decision.
    func playingDetector() -> PlaybackDetector {
        // Layer 1: CoreAudio active output stream check (Yandex Music, Firefox, Chrome, Safari, VLC, etc.)
        if isCoreAudioOutputPlaying() {
            return .coreAudio
        }

        // Layer 2: MediaRemote NowPlaying Application isPlaying check
        if isMediaRemotePlaying() {
            return .mediaRemote
        }

        // Layer 3: Apple Music dedicated player state (process-guarded, never launches Music.app)
        if isAppleMusicPlaying() {
            return .music
        }

        // Layer 4: Spotify dedicated player state (process-guarded)
        if isSpotifyPlaying() {
            return .spotify
        }

        // Layer 5: IOKit power assertions (video-playing in browsers preventing display sleep)
        if isIOKitVideoPlaying() {
            return .iokitVideo
        }

        return .none
    }

    /// Asynchronous check for backward compatibility with existing callers.
    func isMediaPlaying(completion: @escaping (Bool) -> Void) {
        let playing = isAnyMediaPlaying()
        completion(playing)
    }

    // MARK: - Media Actions

    /// Pauses only the sources that are verified playing right now.
    /// MediaRemote Pause is sent only when Now Playing itself is playing —
    /// CoreAudio / IOKit noise is not an addressable client.
    func pauseBackgroundMedia() {
        let playingPID = coreAudioRunningOutputPID()
        let snapshot = currentSnapshot(coreAudioPlaying: playingPID != nil)
        let plan = MediaPlaybackRouting.pausePlan(from: snapshot, pausedPID: playingPID)
        // A probe-only snapshot (CoreAudio / IOKit, no addressed player) must
        // not invalidate a resume confirmation that is still in flight.
        // A CoreAudio PID alone does not store a plan and does not pause
        // MediaRemote — only Music / Spotify / Now Playing set touchesAnything.
        if plan.touchesAnything {
            resumeEpoch &+= 1
            pausedPlan = plan
        }
        let detector = playingDetector()
        let pidText = plan.pausedPID.map { String($0) } ?? "nil"
        AppLogger.shared.logPipeline(
            stage: "media",
            action: "pause",
            reason: "detector=\(detector.rawValue) paused_source=\(plan.pausedSource.rawValue) pid=\(pidText)"
        )
        guard plan.touchesAnything else { return }

        if plan.music {
            let sent = runPlayerScript("tell application \"Music\" to pause")
            logMediaCommand(action: "pause", command: "Music", sent: sent)
        }
        if plan.spotify {
            let sent = runPlayerScript("tell application \"Spotify\" to pause")
            logMediaCommand(action: "pause", command: "Spotify", sent: sent)
        }
        if plan.mediaRemote {
            // Safe: rcd launches Music.app only for hardware key codes, not for
            // an explicit kMRMediaRemoteCommandPause.
            let sent = sendCommand("kMRMediaRemoteCommandPause")
            logMediaCommand(action: "pause", command: "MediaRemote", sent: sent)
        }
    }

    /// Resumes ONLY the sources stored by the matching pause. A nil plan (this
    /// controller never paused, or the caller already consumed the plan) sends
    /// no Play — that is how already-paused media stays paused.
    /// Never launches Music.app: Play goes to the same addressed source.
    func resumeBackgroundMedia() {
        // Decide from the stored plan, then drop it. A nil plan is `.none`
        // and the guard sends no Play — already-paused media stays paused.
        let stored = pausedPlan
        let plan = MediaPlaybackRouting.resumePlan(paused: stored)
        resumeEpoch &+= 1
        let epoch = resumeEpoch
        pausedPlan = nil
        let detector = playingDetector()
        AppLogger.shared.logPipeline(
            stage: "media",
            action: "resume",
            reason: "detector=\(detector.rawValue) resume_source=\(plan.resumeSource.rawValue) sent=\(plan.sendsPlay)"
        )
        guard plan.sendsPlay else { return }
        let pausedPID = stored?.pausedPID

        if plan.music {
            sendResume(source: .music, epoch: epoch, pausedPID: pausedPID) {
                self.runPlayerScript("tell application \"Music\" to play")
            }
        }
        if plan.spotify {
            sendResume(source: .spotify, epoch: epoch, pausedPID: pausedPID) {
                self.runPlayerScript("tell application \"Spotify\" to play")
            }
        }
        if plan.mediaRemote {
            sendResume(source: .mediaRemote, epoch: epoch, pausedPID: pausedPID) {
                self.sendCommand("kMRMediaRemoteCommandPlay")
            }
        }
    }

    /// One Play, then a single repeat into the SAME source if it is still not
    /// playing after ~0.4s. A stale epoch (newer pause, or this resume already
    /// finished) drops the repeat. Does not start Music.app.
    private func sendResume(
        source: MediaPlaybackRouting.Source,
        epoch: Int,
        pausedPID: pid_t?,
        play: @escaping () -> Bool
    ) {
        let command = source.rawValue
        let running = source == .mediaRemote || isAppRunning(bundleIdentifier(for: source))
        guard running else {
            logMediaCommand(action: "resume", command: command, sent: false, failure: "app_not_running")
            logResumeConfirmation(source: source, sent: false, confirmed: false)
            return
        }
        let sent = play()
        logMediaCommand(action: "resume", command: command, sent: sent)
        guard sent else {
            logResumeConfirmation(source: source, sent: false, confirmed: false)
            return
        }
        confirmResume(source: source, attempt: 1, sent: true, epoch: epoch, pausedPID: pausedPID, play: play)
    }

    private func confirmResume(
        source: MediaPlaybackRouting.Source,
        attempt: Int,
        sent: Bool,
        epoch: Int,
        pausedPID: pid_t?,
        play: @escaping () -> Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.resumeEpoch == epoch else { return }
            // PID mismatch is telemetry only. Success stays `isSourcePlaying`
            // of this same source; a repeat uses `shouldRepeatPlay` and the
            // same `play` closure. Never Play Music, Spotify, or Now Playing
            // because some other CoreAudio client is running.
            if let pausedPID,
               let currentPID = self.coreAudioRunningOutputPID(),
               MediaPlaybackRouting.coreAudioPIDMismatch(pausedPID: pausedPID, currentPID: currentPID) {
                AppLogger.shared.logPipeline(
                    stage: "media",
                    code: "pid_mismatch",
                    action: "resume",
                    reason: "paused_pid=\(pausedPID) current_pid=\(currentPID)"
                )
            }
            let confirmed = MediaPlaybackRouting.isSourcePlaying(source, snapshot: self.currentSnapshot())
            if confirmed {
                self.logResumeConfirmation(source: source, sent: sent, confirmed: true)
                return
            }
            guard MediaPlaybackRouting.shouldRepeatPlay(attempt: attempt, confirmed: confirmed) else {
                self.logResumeConfirmation(source: source, sent: sent, confirmed: false)
                return
            }
            let repeated = play()
            self.logMediaCommand(action: "resume", command: source.rawValue, sent: repeated)
            self.confirmResume(
                source: source,
                attempt: attempt + 1,
                sent: repeated,
                epoch: epoch,
                pausedPID: pausedPID,
                play: play
            )
        }
    }

    private func bundleIdentifier(for source: MediaPlaybackRouting.Source) -> String {
        switch source {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .mediaRemote, .none: return ""
        }
    }

    private func logResumeConfirmation(source: MediaPlaybackRouting.Source, sent: Bool, confirmed: Bool) {
        if confirmed {
            AppLogger.shared.logPipeline(
                stage: "media",
                action: "resume",
                reason: "resume_source=\(source.rawValue) sent=\(sent) confirmed=true"
            )
        } else {
            AppLogger.shared.logPipeline(
                stage: "media",
                code: "resume_not_confirmed",
                action: "resume",
                reason: "source=\(source.rawValue) resume_source=\(source.rawValue) sent=\(sent) confirmed=false"
            )
        }
    }

    private func isAppRunning(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    private func currentSnapshot(coreAudioPlaying: Bool? = nil) -> MediaPlaybackRouting.Snapshot {
        MediaPlaybackRouting.Snapshot(
            musicPlaying: isAppleMusicPlaying(),
            spotifyPlaying: isSpotifyPlaying(),
            mediaRemotePlaying: isMediaRemotePlaying(),
            coreAudioPlaying: coreAudioPlaying ?? isCoreAudioOutputPlaying(),
            iokitVideoPlaying: isIOKitVideoPlaying()
        )
    }

    // MARK: - Private Probes

    /// Checks if any non-system process is currently outputting audio via CoreAudio hardware IO.
    /// Accurately detects Electron apps (Yandex Music), web browsers (YouTube/video in Firefox/Chrome/Safari), VLC, etc.
    func isCoreAudioOutputPlaying() -> Bool {
        coreAudioRunningOutputPID() != nil
    }

    /// First non-system PID with a running CoreAudio output, or nil.
    /// Same process list, own-pid skip and bundle prefixes as the Bool probe.
    /// Telemetry for the pause plan only — never an address for Play.
    func coreAudioRunningOutputPID() -> pid_t? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &processIDs) == noErr else {
            return nil
        }

        let myPid = getpid()
        let ignoredBundlePrefixes = [
            "com.apple.audiomxd",
            "systemsoundserverd",
            "com.apple.mediaremoted",
            "com.apple.cmio",
            "com.apple.audio"
        ]

        for pidObj in processIDs {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(pidObj, &pidAddr, 0, nil, &pidSize, &pid)
            guard pid != myPid && pid > 0 else { continue }

            var isRunningOut: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectGetPropertyData(pidObj, &outAddr, 0, nil, &outSize, &isRunningOut)
            guard isRunningOut != 0 else { continue }

            var bundleID: CFString = "" as CFString
            var strSize = UInt32(MemoryLayout<CFString>.size)
            var strAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            withUnsafeMutablePointer(to: &bundleID) { ptr in
                _ = AudioObjectGetPropertyData(pidObj, &strAddr, 0, nil, &strSize, ptr)
            }
            let bId = bundleID as String
            if !ignoredBundlePrefixes.contains(where: { bId.hasPrefix($0) }) {
                AppLogger.shared.log("🎵 MediaController: active audio player found via CoreAudio: PID=\(pid), bundle=\(bId)")
                return pid
            }
        }
        return nil
    }

    /// Checks if MediaRemote reports active playback using canonical MRMediaRemoteGetNowPlayingApplicationIsPlaying.
    private func isMediaRemotePlaying() -> Bool {
        // Primary check: MRMediaRemoteGetNowPlayingApplicationIsPlaying (returns Bool directly)
        if let isPlayingSym = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            typealias FnIsPlaying = @convention(c) (DispatchQueue, @convention(block) @escaping (Bool) -> Void) -> Void
            let fn = unsafeBitCast(isPlayingSym, to: FnIsPlaying.self)
            var isPlaying = false
            let sema = DispatchSemaphore(value: 0)
            fn(DispatchQueue.global(qos: .userInitiated)) { playing in
                isPlaying = playing
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 0.15) // 150ms timeout
            if isPlaying {
                return true
            }
        }

        // Secondary check: NowPlaying Info playback rate (some web/electron players update rate > 0)
        if let getNowPlayingInfo = symbol("MRMediaRemoteGetNowPlayingInfo") {
            typealias FnInfo = @convention(c) (DispatchQueue, @convention(block) @escaping (CFDictionary?) -> Void) -> Void
            let fn = unsafeBitCast(getNowPlayingInfo, to: FnInfo.self)
            var isRatePositive = false
            let sema = DispatchSemaphore(value: 0)
            fn(DispatchQueue.global(qos: .userInitiated)) { dict in
                if let dict = dict as? [String: Any],
                   let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue,
                   rate > 0.0 {
                    isRatePositive = true
                }
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 0.15)
            if isRatePositive {
                return true
            }
        }

        return false
    }

    /// Checks Apple Music state ONLY if process is actively running in NSWorkspace.
    /// Guarantees Music.app will never be launched if closed.
    private func isAppleMusicPlaying() -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
            return false
        }
        let script = "tell application \"Music\" to get player state"
        if let state = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue {
            return state.lowercased() == "playing"
        }
        return false
    }

    /// Checks Spotify state ONLY if process is actively running in NSWorkspace.
    private func isSpotifyPlaying() -> Bool {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return false
        }
        let script = "tell application \"Spotify\" to get player state"
        if let state = NSAppleScript(source: script)?.executeAndReturnError(nil).stringValue {
            return state.lowercased() == "playing"
        }
        return false
    }

    /// Checks if any application currently holds a display-sleep video assertion (HTML5 video playback).
    /// Ignores generic headphone / audio-out system sleep assertions.
    private func isIOKitVideoPlaying() -> Bool {
        var assertionsByProcess: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard status == kIOReturnSuccess, let unmanaged = assertionsByProcess else { return false }
        guard let dict = unmanaged.takeRetainedValue() as? [NSNumber: [NSDictionary]] else { return false }
        for (_, assertions) in dict {
            for a in assertions {
                let type = a["AssertType"] as? String ?? ""
                let name = a["AssertName"] as? String ?? ""
                if type == "PreventUserIdleDisplaySleep" && name.contains("video-playing") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Media Remote Dispatch

    private func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    /// Runs a player AppleScript. Returns false when the script object or the
    /// execution reports an error. The error dictionary is not logged (it can
    /// contain the player UI string).
    @discardableResult
    private func runPlayerScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        return error == nil
    }

    /// `true` only when the private command symbol exists and reports success.
    @discardableResult
    private func sendCommand(_ commandKey: String) -> Bool {
        guard let commandValue = Self.commands[commandKey] else { return false }
        guard let send = symbol("MRMediaRemoteSendCommand") else { return false }
        typealias FnSend = @convention(c) (Int32, AnyObject?) -> Bool
        let fn = unsafeBitCast(send, to: FnSend.self)
        return fn(commandValue, nil)
    }

    private func logMediaCommand(action: String, command: String, sent: Bool, failure: String? = nil) {
        if sent {
            AppLogger.shared.logPipeline(
                stage: "media",
                action: action,
                reason: "command=\(command) sent=true"
            )
        } else {
            let why = failure ?? (command == "MediaRemote" ? "symbol_missing_or_rejected" : "applescript_error")
            AppLogger.shared.logPipeline(
                stage: "media",
                code: "command_not_sent",
                action: action,
                reason: "command=\(command) \(why)"
            )
        }
    }
}
