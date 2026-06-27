import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var dictation: DictationController!
    private var hotkey: HotkeyManager!
    private let settingsWindow = SettingsWindow()
    private let onboardingWindow = OnboardingWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No dock icon / main window — pure menu-bar agent.
        NSApp.setActivationPolicy(.accessory)

        // Keep the ASR model resident so dictation has no cold start.
        WhisperServerProcess.shared.start()

        statusBar = StatusBarController()
        dictation = DictationController(statusBar: statusBar)
        hotkey = HotkeyManager(
            onActivate: { [weak dictation] in dictation?.startDictation() },
            onDeactivate: { [weak dictation] in dictation?.stopDictation() }
        )
        hotkey.install()

        statusBar.onOpenSettings = { [weak self] in
            self?.settingsWindow.show()
        }
        statusBar.onConfigureHotkey = { [weak self] in
            // If permissions are missing, onboarding covers the guidance.
            // Otherwise open Keyboard settings to disable Apple dictation.
            if PermissionChecker.shared.allGranted {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                self?.onboardingWindow.show()
            }
        }
        statusBar.onOpenOnboarding = { [weak self] in
            self?.onboardingWindow.show()
        }

        // Onboarding: show on first run, or any time permissions are missing.
        // Trigger the mic + accessibility prompts up front so the user sees them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            PermissionChecker.shared.requestMicrophone()
            PermissionChecker.shared.requestAccessibility()
            if !OnboardingWindow.completed || !PermissionChecker.shared.allGranted {
                self.onboardingWindow.show()
            }
            self.applyLaunchAtLogin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
        WhisperServerProcess.shared.stop()
    }

    // MARK: Launch at login

    private func applyLaunchAtLogin() {
        let enabled = AppSettings.shared.launchAtLogin
        let bundleId = "app.singar"
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleId).plist")

        if enabled {
            let exec = Bundle.main.bundlePath.isEmpty
                ? CommandLine.arguments.first ?? ""
                : "\(Bundle.main.bundlePath)/Contents/MacOS/SingAR"
            let plist: [String: Any] = [
                "Label": bundleId,
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? data.write(to: plistURL)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
