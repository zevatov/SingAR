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

    private var didSendMediaRemotePause = false
    private var didPauseAppleMusic = false
    private var didPauseSpotify = false

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    // MARK: - Playback Detection

    /// Synchronous multi-layer check if ANY media (Spotify, Yandex Music, YouTube/Browser, Music.app)
    /// is actively outputting sound or video right now.
    func isAnyMediaPlaying() -> Bool {
        // Layer 1: CoreAudio active output stream check (Yandex Music, Firefox, Chrome, Safari, VLC, etc.)
        if isCoreAudioOutputPlaying() {
            return true
        }

        // Layer 2: MediaRemote NowPlaying Application isPlaying check
        if isMediaRemotePlaying() {
            return true
        }

        // Layer 3: Apple Music dedicated player state (process-guarded, never launches Music.app)
        if isAppleMusicPlaying() {
            return true
        }

        // Layer 4: Spotify dedicated player state (process-guarded)
        if isSpotifyPlaying() {
            return true
        }

        // Layer 5: IOKit power assertions (video-playing in browsers preventing display sleep)
        if isIOKitVideoPlaying() {
            return true
        }

        return false
    }

    /// Asynchronous check for backward compatibility with existing callers.
    func isMediaPlaying(completion: @escaping (Bool) -> Void) {
        let playing = isAnyMediaPlaying()
        completion(playing)
    }

    // MARK: - Media Actions

    /// Pauses background media across active sources immediately.
    /// Only pauses sources that are verified to be currently playing.
    func pauseBackgroundMedia() {
        didSendMediaRemotePause = false
        didPauseAppleMusic = false
        didPauseSpotify = false

        // 1. Explicitly pause Apple Music if actively playing
        if isAppleMusicPlaying() {
            didPauseAppleMusic = true
            _ = NSAppleScript(source: "tell application \"Music\" to pause")?.executeAndReturnError(nil)
            AppLogger.shared.log("🎵 MediaController: Apple Music paused")
        }

        // 2. Explicitly pause Spotify if actively playing
        if isSpotifyPlaying() {
            didPauseSpotify = true
            _ = NSAppleScript(source: "tell application \"Spotify\" to pause")?.executeAndReturnError(nil)
            AppLogger.shared.log("🎵 MediaController: Spotify paused")
        }

        // 3. Send MediaRemote Pause command (controls Yandex Music, YouTube, Safari, Chrome, Firefox, Podcasts)
        // Safe: never launches Apple Music (rcd only responds to hardware key codes, not explicit kMRMediaRemoteCommandPause)
        didSendMediaRemotePause = true
        sendCommand("kMRMediaRemoteCommandPause")
        AppLogger.shared.log("🎵 MediaController: MediaRemote NowPlaying paused")
    }

    /// Resumes playback ONLY for sources that were actively playing and paused by us.
    /// Never sends blind Play commands to avoid rcd launching Music.app.
    func resumeBackgroundMedia() {
        // 1. Resume Apple Music if paused by us
        if didPauseAppleMusic {
            // Extra safety guard: verify Music is still running before executing AppleScript
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
                _ = NSAppleScript(source: "tell application \"Music\" to play")?.executeAndReturnError(nil)
                AppLogger.shared.log("🎵 MediaController: Apple Music resumed")
            }
            didPauseAppleMusic = false
        }

        // 2. Resume Spotify if paused by us
        if didPauseSpotify {
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
                _ = NSAppleScript(source: "tell application \"Spotify\" to play")?.executeAndReturnError(nil)
                AppLogger.shared.log("🎵 MediaController: Spotify resumed")
            }
            didPauseSpotify = false
        }

        // 3. Resume MediaRemote NowPlaying only if we explicitly paused it
        if didSendMediaRemotePause {
            sendCommand("kMRMediaRemoteCommandPlay")
            AppLogger.shared.log("🎵 MediaController: MediaRemote NowPlaying resumed")
            didSendMediaRemotePause = false
        }
    }

    // MARK: - Private Probes

    /// Checks if any non-system process is currently outputting audio via CoreAudio hardware IO.
    /// Accurately detects Electron apps (Yandex Music), web browsers (YouTube/video in Firefox/Chrome/Safari), VLC, etc.
    func isCoreAudioOutputPlaying() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return false
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &processIDs) == noErr else {
            return false
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
                return true
            }
        }
        return false
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

    private func sendCommand(_ commandKey: String) {
        guard let commandValue = Self.commands[commandKey] else { return }
        guard let send = symbol("MRMediaRemoteSendCommand") else { return }
        typealias FnSend = @convention(c) (Int32, AnyObject?) -> Bool
        let fn = unsafeBitCast(send, to: FnSend.self)
        _ = fn(commandValue, nil)
    }
}
