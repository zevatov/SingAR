import SwiftUI
import AppKit

final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyWindowController: HistoryWindow?

    @MainActor
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindow {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SingAR — Настройки"
        let hostingView = NSHostingView(rootView: SettingsView())
        hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 540, height: 640)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible

        self.settingsWindow = window
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
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
            NSApp.deactivate()
        }
    }

    @MainActor
    func showOnboarding() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = onboardingWindow {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Добро пожаловать в SingAR"
        let hostingView = NSHostingView(rootView: OnboardingView())
        hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 520, height: 440)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible

        self.onboardingWindow = window
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
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
        onboardingWindow?.performClose(nil)
        onboardingWindow = nil
        NSApp.deactivate()
    }

    @objc private func onboardingWindowWillClose(notification: Notification) {
        if let window = notification.object as? NSWindow, window == onboardingWindow {
            onboardingWindow = nil
            NSApp.deactivate()
        }
    }

    @MainActor
    func showHistory() {
        if historyWindowController == nil {
            historyWindowController = HistoryWindow()
        }
        historyWindowController?.show()
    }
}
