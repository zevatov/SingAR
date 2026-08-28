import AppKit
import SwiftUI

/// Owns the menu bar status item with a combined Microphone glyph + live Status Dot (🟢/🟡/🔴),
/// NSPopover with SwiftUI MenuBarView, and click handling.
final class StatusBarController: NSObject {

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let settings = AppSettings.shared
    private var status: AppStatus = .idle
    private var permCheckTimer: Timer?

    /// Wired by AppDelegate so menu actions can open UI.
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.contentSize = NSSize(width: 280, height: 380)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        renderButton()

        // Periodically refresh status dot in case permissions change in System Settings
        permCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderButton()
        }
    }

    deinit {
        permCheckTimer?.invalidate()
    }

    // MARK: Click handling (Left: Popover, Right: Context Menu)

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showRightClickMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "SingAR (Gemini 3.5)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let enabledItem = NSMenuItem(
            title: settings.enabled ? "Поставить на паузу" : "Возобновить работу",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        menu.addItem(enabledItem)

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let onboardingItem = NSMenuItem(title: "Разрешения...", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выход", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Reset so left-click continues opening popover
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        renderButton()
    }

    @objc private func openSettings() {
        DispatchQueue.main.async {
            WindowManager.shared.showSettings()
        }
    }

    @objc private func openOnboarding() {
        DispatchQueue.main.async {
            WindowManager.shared.showOnboarding()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: Public API

    func setStatus(_ status: AppStatus) {
        self.status = status
        renderButton(animated: true)
    }

    func flashStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem.button else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                button.animator().contentTintColor = .systemRed
            }, completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.renderButton(animated: true)
                }
            })
        }
    }

    var statusItemButtonFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.frame)
    }

    // MARK: Combined Menu Bar Button Rendering (Microphone + Status Dot)

    func renderButton(animated: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }

            let isEnabled = self.settings.enabled
            let permissionsOk = PermissionChecker.shared.allGranted

            // 1. Determine Status Dot Color
            let dotColor: NSColor
            if !isEnabled {
                dotColor = .systemRed       // 🔴 Paused
            } else if !permissionsOk {
                dotColor = .systemOrange    // 🟡 Missing permissions
            } else {
                dotColor = .systemGreen     // 🟢 Active & Ready
            }

            // 2. Microphone Glyph
            let symbolName = isEnabled ? self.status.symbol : "mic.slash"
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            guard let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: self.status.tooltip)?
                .withSymbolConfiguration(config) else { return }

            let totalWidth: CGFloat = 28
            let totalHeight: CGFloat = 18

            let combinedImage = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
                // Draw Microphone icon on the left (white/template by default)
                let glyphRect = NSRect(
                    x: 0,
                    y: (totalHeight - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                )

                if self.status != .idle && isEnabled {
                    self.status.color.set()
                    glyph.draw(in: glyphRect)
                } else {
                    let isDark = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                        || (button.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                        || (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                    let baseColor = isDark ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
                    baseColor.set()
                    glyph.draw(in: glyphRect)
                }

                // Draw Status Circle Dot on the right (🟢/🟡/🔴)
                let dotSize: CGFloat = 6.0
                let dotRect = NSRect(
                    x: totalWidth - dotSize - 1,
                    y: (totalHeight - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                let path = NSBezierPath(ovalIn: dotRect)
                dotColor.setFill()
                path.fill()

                return true
            }

            button.image = combinedImage
            button.toolTip = isEnabled ? (permissionsOk ? self.status.tooltip : "Требуются разрешения") : "SingAR на паузе"
        }
    }
}
