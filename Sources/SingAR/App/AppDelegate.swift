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
            }
        )

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

        // If permissions are not granted, present the Onboarding window without system alert spam
        let hasAllPermissions = PermissionChecker.shared.allGranted
        if !hasAllPermissions {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WindowManager.shared.showOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.uninstall()
    }
}
