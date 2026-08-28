import Foundation
import AppKit

/// Pauses background media while dictating — a feature Apple dictation lacks.
/// Uses the private `MediaRemote.framework`, accessed dynamically so the app
/// still launches if symbols are unavailable.
///
/// Pause is best-effort. Resume is intentionally disabled: sending a generic
/// Play command after dictation can launch Apple Music when no media was active.
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

    /// Pause whatever is playing. Never report resumable state because this
    /// private API does not synchronously prove that media was playing.
    func pauseBackgroundMedia() -> Bool {
        guard handle != nil else { return false }
        sendCommand("kMRMediaRemoteCommandPause")
        return false
    }

    /// Kept for caller compatibility. Generic Play is unsafe: when nothing was
    /// paused it can start Apple Music after releasing Right Option.
    func resumeBackgroundMedia() {}

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
