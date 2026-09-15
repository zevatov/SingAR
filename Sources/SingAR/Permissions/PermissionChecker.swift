import AppKit
import AVFoundation
import ApplicationServices
import IOKit.hid
import Speech

enum PermissionStatus: String {
    case granted
    case denied
    case unknown
}

enum PermissionKind: CaseIterable {
    case microphone
    case accessibility
    case speechRecognition

    var title: String {
        switch self {
        case .microphone:          return "Микрофон"
        case .accessibility:       return "Универсальный доступ"
        case .speechRecognition:   return "Распознавание речи"
        }
    }

    var why: String {
        switch self {
        case .microphone:          return "нужен для захвата речи с микрофона"
        case .accessibility:       return "нужен для глобального хоткея и вставки текста (Cmd+V)"
        case .speechRecognition:   return "нужно для локальной live-транскрипции"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        }
    }
}

final class PermissionChecker {

    static let shared = PermissionChecker()
    private init() {}

    /// Current live status of each permission.
    func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            if #available(macOS 14.0, *) {
                switch AVAudioApplication.shared.recordPermission {
                case .granted:       return .granted
                case .denied:        return .denied
                case .undetermined:  return .unknown
                @unknown default:    return .unknown
                }
            } else {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:    return .granted
                case .denied:        return .denied
                case .notDetermined, .restricted: return .unknown
                @unknown default:    return .unknown
                }
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:                   return .granted
            case .denied:                       return .denied
            case .notDetermined, .restricted:   return .unknown
            @unknown default:                   return .unknown
            }
        }
    }

    /// True only when all required permissions are granted.
    var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status(of: $0) == .granted }
    }

    /// True when the minimum essential permissions for dictation (mic + AX) are granted.
    var corePermissionsGranted: Bool {
        status(of: .microphone) == .granted && status(of: .accessibility) == .granted
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:        requestMicrophone()
        case .accessibility:     requestAccessibility()
        case .speechRecognition: requestSpeechRecognition()
        }
    }

    /// Request microphone permission (triggers system prompt or opens settings if denied).
    func requestMicrophone() {
        if #available(macOS 14.0, *) {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                AVAudioApplication.requestRecordPermission { _ in }
            } else {
                openSettings(for: .microphone)
            }
        } else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSettings(for: .microphone)
            }
        }
    }

    /// Request accessibility (triggers system prompt or opens Settings).
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openSettings(for: .accessibility)
        }
    }

    /// Request speech recognition.
    func requestSpeechRecognition() {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        } else {
            openSettings(for: .speechRecognition)
        }
    }

    /// Open the System Settings pane for a specific permission.
    func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}
