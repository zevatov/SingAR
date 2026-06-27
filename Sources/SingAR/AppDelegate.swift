import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var dictation: DictationController!
    private var hotkey: HotkeyManager!
    private let settingsWindow = SettingsWindow()

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
            self?.openHotkeyHelp()
        }

        // Permissions + launch-at-login, deferred slightly so the menu shows first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPermissions()
            self?.applyLaunchAtLogin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
        WhisperServerProcess.shared.stop()
    }

    // MARK: Permissions

    private func checkPermissions() {
        // Accessibility (for CGEventTap + Cmd+V injection).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
        if !trusted {
            NSLog("[SingAR] Accessibility permission not granted — hotkey inactive.")
        }

        // Microphone: trigger the system prompt by touching AVAudioApplication.
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                NSLog("[SingAR] Microphone permission denied.")
            }
        }
    }

    private func openHotkeyHelp() {
        // Guide the user to disable Apple dictation and grant Input Monitoring.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Launch at login

    /// Toggle a launch agent so SingAR starts at login (no SMAppService dependency
    /// on older macOS; works via a standard LaunchAgent plist).
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
