import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBar: StatusBarController!
    private var dictation: DictationController!
    private var hotkey: HotkeyManager!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as accessory app (menu-bar only, no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Initialize UI & Core subsystems
        statusBar = StatusBarController()
        dictation = DictationController(statusBar: statusBar)

        // Wire hotkey triggers
        hotkey = HotkeyManager(
            onActivate: { [weak self] in
                self?.dictation.startDictation()
            },
            onDeactivate: { [weak self] in
                self?.dictation.stopDictation()
            },
            onCancel: { [weak self] in
                self?.dictation.cancelDictation()
            }
        )
        hotkey.canCancel = { [weak self] in self?.dictation.canCancel ?? false }

        // Reset hotkey state if text focus is lost
        dictation.onFocusLost = { [weak self] in
            self?.hotkey.forceReset()
        }

        // Wire status bar open actions
        statusBar.onOpenSettings = {
            WindowManager.shared.showSettings()
        }
        statusBar.onOpenOnboarding = {
            WindowManager.shared.showOnboarding()
        }

        // React to enable/pause changes
        AppSettings.shared.$enabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.statusBar.renderButton()
            }
            .store(in: &cancellables)

        // Install global hotkey monitor
        hotkey.install()

        // Ensure no stray windows are visible on launch (menu bar accessory app)
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.orderOut(nil)
            }
        }

        // Present Onboarding on first launch only if essential permissions (mic + AX) are missing
        let shouldShowOnboarding = !AppSettings.shared.hasCompletedOnboarding && !PermissionChecker.shared.corePermissionsGranted
        if shouldShowOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WindowManager.shared.showOnboarding()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
    }
}
