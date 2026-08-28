import AppKit
import SwiftUI

/// Manages the NSStatusItem in the macOS menu bar.
/// Renders a crisp white monochrome microphone icon and a dynamic status dot (🟢 Ready / 🟡 Permissions / 🔴 Paused).
final class StatusBarController {

    private let statusItem: NSStatusItem
    private let settings = AppSettings.shared
    private(set) var status: AppStatus = .idle
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var permissionsTimer: Timer?

    var onOpenSettings: (() -> Void)?
    var onOpenOnboarding: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupStatusItem()
        renderButton()
        setupPermissionsObserver()
    }

    deinit {
        permissionsTimer?.invalidate()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPermissionsObserver() {
        // Poll permissions every 1s to reactively update the menu bar dot (🟡 -> 🟢)
        permissionsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.renderButton()
        }
    }

    // MARK: Actions

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            toggleEnabled()
        } else {
            togglePopover(sender)
        }
    }

    private func toggleEnabled() {
        withAnimation {
            settings.enabled.toggle()
        }
        renderButton(animated: true)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            closePopover()
        } else {
            showPopover(sender)
        }
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        DictationHistory.shared.reload()
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 290, height: 280)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = pop

        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        sender.window?.makeKey()

        // Global click-outside monitor
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: Status Updates

    func setStatus(_ newStatus: AppStatus) {
        guard status != newStatus else { return }
        status = newStatus
        renderButton(animated: true)
    }

    func flashStatus() {
        guard let button = statusItem.button else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            button.alphaValue = 0.2
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                button.alphaValue = 1.0
            }, completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.renderButton(animated: true)
                }
            })
        })
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

            // 2. Microphone Glyph Styling
            let isDark = (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark")
                || (button.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                || (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            let baseColor: NSColor = isDark ? .white : NSColor(white: 0.1, alpha: 1.0)
            let activeColor = (self.status != .idle && isEnabled) ? self.status.color : baseColor

            let symbolName = isEnabled ? self.status.symbol : "mic.slash"
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [activeColor])
            let finalConfig = config.applying(colorConfig)

            guard let glyph = NSImage(systemSymbolName: symbolName, accessibilityDescription: self.status.tooltip)?
                .withSymbolConfiguration(finalConfig) else { return }

            let totalWidth: CGFloat = 28
            let totalHeight: CGFloat = 18

            let combinedImage = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
                // Draw Microphone icon on the left
                let glyphRect = NSRect(
                    x: 0,
                    y: (totalHeight - glyph.size.height) / 2,
                    width: glyph.size.width,
                    height: glyph.size.height
                )

                // High-precision mask fill to guarantee pure white in dark mode
                if let cgImage = glyph.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let ctx = NSGraphicsContext.current?.cgContext
                    ctx?.saveGState()
                    ctx?.clip(to: glyphRect, mask: cgImage)
                    activeColor.setFill()
                    ctx?.fill(glyphRect)
                    ctx?.restoreGState()
                } else {
                    activeColor.set()
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
