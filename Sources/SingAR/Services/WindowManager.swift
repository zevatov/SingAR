import SwiftUI
import AppKit

final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyWindowController: HistoryWindow?

    @MainActor
    func showSettings() {
        if let window = settingsWindow {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SingAR — Настройки"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func settingsWindowWillClose(notification: Notification) {
        if let window = notification.object as? NSWindow, window == settingsWindow {
            settingsWindow = nil
        }
    }

    @MainActor
    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let onboardingView = OnboardingView()
        let hostingView = NSHostingView(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SingAR — Разрешения"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        self.onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onboardingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @MainActor
    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    @objc private func onboardingWindowWillClose(notification: Notification) {
        if let window = notification.object as? NSWindow, window == onboardingWindow {
            onboardingWindow = nil
        }
    }

    @MainActor
    func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindow()
        }
        historyWindowController?.showWindow(nil)
        historyWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
