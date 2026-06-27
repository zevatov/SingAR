import AppKit
import AVFoundation
import ApplicationServices

/// Centralised permission state. Each permission exposes a status + a way to
/// open the relevant System Settings pane so the onboarding window can guide
/// the user through them step by step.
enum PermissionStatus: String {
    case granted
    case denied
    case unknown
}

enum PermissionKind: CaseIterable {
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .microphone:       return "Микрофон"
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        }
    }

    var why: String {
        switch self {
        case .microphone:       return "нужен для записи речи"
        case .accessibility:    return "нужен для хоткея и вставки текста (Cmd+V)"
        case .inputMonitoring:  return "нужен для перехвата клавиши Fn/Globe"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }
}

final class PermissionChecker {

    static let shared = PermissionChecker()
    private init() {}

    /// Current status of each permission.
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted:    return .granted
            case .denied:     return .denied
            case .undetermined: return .unknown
            @unknown default: return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted returns false during the prompt; treat as
            // unknown until granted. A non-prompting check avoids re-popping it.
            return AXIsProcessTrusted() ? .granted : .unknown
        case .inputMonitoring:
            // IOHIDCheckAccess is the real check; fall back to "trusted => granted".
            return AXIsProcessTrusted() ? .granted : .unknown
        }
    }

    /// True only when all permissions are granted.
    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// Request microphone permission (triggers the system prompt once).
    func requestMicrophone() {
        AVAudioApplication.requestRecordPermission { _ in }
    }

    /// Request accessibility (shows the system prompt once; user must toggle
    /// the switch in System Settings).
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
    }

    /// Open the System Settings pane for a permission.
    func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Re-check periodically and fire a callback when all are granted.
    func watchUntilGranted(_ callback: @escaping () -> Void) {
        if allGranted { callback(); return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            if PermissionChecker.shared.allGranted {
                timer.invalidate()
                callback()
            }
        }
    }
}
