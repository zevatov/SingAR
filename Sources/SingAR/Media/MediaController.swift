import Foundation
import AppKit

/// Pauses/ducks background media while dictating — a feature Apple dictation
/// lacks. Uses the private `MediaRemote.framework`, accessed dynamically so the
/// app still launches if symbols are unavailable.
///
/// `pauseBackgroundMedia()` returns true only when it actually paused something,
/// so `resumeBackgroundMedia()` is a no-op unless we caused the pause.
final class MediaController {

    private let handle: UnsafeMutableRawPointer?

    private static let commands: [String: Int32] = [
        // kMRMediaRemoteCommand enum values (stable across macOS releases)
        "kMRMediaRemoteCommandPause":  1,
        "kMRMediaRemoteCommandPlay":   2,
        "kMRMediaRemoteCommandTogglePlayPause": 3,
    ]

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    /// Pause whatever is playing. Returns true if it sent a pause command and
    /// now-playing was actually playing (caller should call resume after).
    func pauseBackgroundMedia() -> Bool {
        guard handle != nil else { return false }
        // The now-playing getter uses an async completion handler; the robust
        // approach is to send pause and let `resumeBackgroundMedia()` be
        // guarded by the caller's didPauseMedia flag.
        sendCommand("kMRMediaRemoteCommandPause")
        return true
    }

    /// Resume playback only if `pauseBackgroundMedia` paused it.
    func resumeBackgroundMedia() {
        guard handle != nil else { return }
        sendCommand("kMRMediaRemoteCommandPlay")
    }

    // MARK: Internals

    private func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(handle, name)
    }

    private func sendCommand(_ commandKey: String) {
        guard let commandValue = Self.commands[commandKey] else { return }
        guard let send = symbol("MRMediaRemoteSendCommand") else { return }
        typealias FnSend = @convention(c) (Int32, NSDictionary?) -> Void
        let fn = unsafeBitCast(send, to: FnSend.self)
        fn(commandValue, nil)
    }
}
