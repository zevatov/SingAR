import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid

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

    /// Current status of each permission — uses the correct API per kind.
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            // AVCaptureDevice.authorizationStatus is the live, reliable check.
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:  return .granted
            case .denied:      return .denied
            case .notDetermined, .restricted: return .unknown
            @unknown default:  return .unknown
            }
        case .accessibility:
            // AXIsProcessTrusted() does a live check (no prompt). Returns true
            // as soon as the user toggles the switch in System Settings.
            return AXIsProcessTrusted() ? .granted : .unknown
        case .inputMonitoring:
            // IOHIDCheckAccess is the real Input Monitoring check — distinct
            // from Accessibility. kIOHIDRequestTypeListenEvent = 0.
            let result = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            switch result {
            case kIOHIDAccessTypeGranted:       return .granted
            case kIOHIDAccessTypeDenied:        return .denied
            case kIOHIDAccessTypeUnknown:       return .unknown
            default:                            return .unknown
            }
        }
    }

    /// True only when all permissions are granted.
    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// Request microphone permission (triggers the system prompt once).
    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Request accessibility (shows the system prompt once; user must toggle
    /// the switch in System Settings).
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
    }

    /// Request input monitoring (triggers the system prompt; user must toggle
    /// the switch in System Settings).
    func requestInputMonitoring() {
        // IOHIDRequestAccess prompts the user (macOS 10.15+). kIOHIDRequestTypeListenEvent = 0.
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Open the System Settings pane for a permission.
    func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}
