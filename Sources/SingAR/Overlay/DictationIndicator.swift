import AppKit
import QuartzCore

/// Compact Apple-style dictation status capsule anchored under the menu-bar item.
///
/// Shows ONLY dictation status (`recording`, `transcribing`, `inserting`, `failed`),
/// never recognized text preview. Appears/disappears with cross-fade (or instantly
/// if Reduced Motion is enabled). Includes VoiceOver accessibility support.
final class DictationIndicator {

    private let panel: NSPanel
    private let blur: NSVisualEffectView
    private let iconView: NSImageView
    private let statusLabel: NSTextField
    private let waveformContainer: NSView
    private let bars: [CALayer]
    private let barCount = 5

    private var currentStatus: AppStatus = .idle
    private var smoothedLevel: CGFloat = 0

    init() {
        let width: CGFloat = 176
        let height: CGFloat = 40

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        blur.addSubview(iconView)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .labelColor
        blur.addSubview(statusLabel)

        waveformContainer = NSView()
        waveformContainer.translatesAutoresizingMaskIntoConstraints = false
        waveformContainer.wantsLayer = true
        blur.addSubview(waveformContainer)

        var createdBars: [CALayer] = []
        let barW: CGFloat = 2.5
        let barGap: CGFloat = 2.5
        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemRed.cgColor
            bar.cornerRadius = 1.25
            let x = CGFloat(i) * (barW + barGap)
            bar.frame = CGRect(x: x, y: 11, width: barW, height: 4)
            waveformContainer.layer?.addSublayer(bar)
            createdBars.append(bar)
        }
        bars = createdBars

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: blur.centerYAnchor),

            waveformContainer.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            waveformContainer.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            waveformContainer.widthAnchor.constraint(equalToConstant: CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap),
            waveformContainer.heightAnchor.constraint(equalToConstant: 26)
        ])

        updateAccessibility(status: .idle)
    }

    // MARK: Public API

    /// Update status capsule state (icon, label, waveform visibility).
    func setStatus(_ status: AppStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentStatus = status
            self.statusLabel.stringValue = status.menuLabel

            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let img = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.menuLabel)?
                .withSymbolConfiguration(config) {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    let isDark = (self.panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
                    let baseColor = (status == .idle) ? (isDark ? NSColor.white : NSColor.black) : status.color
                    baseColor.set()
                    img.draw(in: rect)
                    return true
                }
                self.iconView.image = tinted
            }

            let isListening = (status == .listening)
            self.waveformContainer.isHidden = !isListening
            if !isListening {
                self.resetWaveform()
            }

            self.updateAccessibility(status: status)
        }
    }

    /// Feed a raw mic level (0...1) to animate waveform during recording.
    func setLevel(_ raw: Float) {
        guard currentStatus == .listening else { return }
        let clamped = CGFloat(max(0, min(1, raw)))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.smoothedLevel += (clamped - self.smoothedLevel) * 0.4
            self.animateBars(level: self.smoothedLevel)
        }
    }

    /// Show capsule anchored under status item button.
    func show(near point: NSPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let width: CGFloat = 176
            let height: CGFloat = 40
            let screen = NSScreen.screens.first
            let frame: NSRect
            if let screen {
                let minX = screen.visibleFrame.minX + 10
                let maxX = screen.visibleFrame.maxX - width - 10
                let x = min(max(point.x - width / 2, minX), maxX)
                frame = NSRect(x: x, y: screen.visibleFrame.maxY - height - 6, width: width, height: height)
            } else {
                frame = NSRect(x: point.x, y: point.y, width: width, height: height)
            }

            self.panel.setFrame(frame, display: true)

            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduceMotion {
                self.panel.alphaValue = 1
                self.panel.orderFrontRegardless()
            } else {
                self.panel.alphaValue = 0
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self.panel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Hide capsule.
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduceMotion {
                self.panel.alphaValue = 0
                self.panel.orderOut(nil)
            } else {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    self.panel.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    self?.panel.orderOut(nil)
                })
            }
        }
    }

    // MARK: Internal Waveform & Accessibility Helpers

    private func animateBars(level: CGFloat) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            resetWaveform()
            return
        }

        let heights: [CGFloat] = bars.indices.map { i in
            let centre = CGFloat(barCount - 1) / 2
            let distance = abs(CGFloat(i) - centre) / centre
            let weight = 1 - distance * 0.55
            let jitter = CGFloat.random(in: 0.85...1.15)
            let rawHeight = (4 + level * 20 * weight) * jitter
            return max(3, min(24, rawHeight))
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (i, bar) in bars.enumerated() {
            let h = heights[i]
            let barW: CGFloat = 2.5
            let barGap: CGFloat = 2.5
            let x = CGFloat(i) * (barW + barGap)
            let y = (26 - h) / 2
            bar.frame = CGRect(x: x, y: y, width: barW, height: h)
            bar.backgroundColor = currentStatus.color.cgColor
        }
        CATransaction.commit()
    }

    private func resetWaveform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let barW: CGFloat = 2.5
            let barGap: CGFloat = 2.5
            let x = CGFloat(i) * (barW + barGap)
            bar.frame = CGRect(x: x, y: 11, width: barW, height: 4)
            bar.backgroundColor = currentStatus.color.cgColor
        }
        CATransaction.commit()
    }

    private func updateAccessibility(status: AppStatus) {
        blur.setAccessibilityElement(true)
        blur.setAccessibilityRole(.group)
        blur.setAccessibilityLabel("Индикатор диктовки")
        blur.setAccessibilityValue(status.tooltip)
    }
}
