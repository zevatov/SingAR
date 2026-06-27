import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var dictation: DictationController!
    private var hotkey: HotkeyManager!

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

        // TODO(M0): prompt for Accessibility / Input Monitoring / Microphone
        // permissions and show guidance in the menu if missing.
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
        WhisperServerProcess.shared.stop()
    }
}
