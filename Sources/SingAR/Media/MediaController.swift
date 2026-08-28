import Foundation
import AppKit

/// Pauses background media while dictating and intelligently resumes only if it was playing.
/// Uses private `MediaRemote.framework` with dynamic symbol lookup for rock-solid stability.
final class MediaController {

    private let handle: UnsafeMutableRawPointer?

    private static let commands: [String: Int32] = [
        "kMRMediaRemoteCommandPause": 1,
        "kMRMediaRemoteCommandPlay": 2,
        "kMRMediaRemoteCommandTogglePlayPause": 3,
    ]

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    /// Check if any media (Spotify, Apple Music, YouTube/Browser) is actively playing.
    func isMediaPlaying(completion: @escaping (Bool) -> Void) {
        guard let getIsPlaying = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            completion(false)
            return
        }
        typealias FnGetIsPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
        let fn = unsafeBitCast(getIsPlaying, to: FnGetIsPlaying.self)
        fn(DispatchQueue.main, completion)
    }

    /// Intelligently pauses media ONLY if it is actively playing.
    /// Passes `true` to completion if media was paused, `false` if it was already silent.
    func pauseIfPlaying(completion: @escaping (Bool) -> Void) {
        isMediaPlaying { [weak self] isPlaying in
            guard let self else {
                completion(false)
                return
            }
            if isPlaying {
                self.sendCommand("kMRMediaRemoteCommandPause")
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// Resumes playback of whatever was previously paused.
    func resumeBackgroundMedia() {
        guard handle != nil else { return }
        sendCommand("kMRMediaRemoteCommandPlay")
    }

    // MARK: Internals

    private func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }

    private func sendCommand(_ commandKey: String) {
        guard let commandValue = Self.commands[commandKey] else { return }
        guard let send = symbol("MRMediaRemoteSendCommand") else { return }
        typealias FnSend = @convention(c) (Int32, NSDictionary?) -> Void
        let fn = unsafeBitCast(send, to: FnSend.self)
        fn(commandValue, nil)
    }
}
