import AppKit
import QuartzCore

/// Compact Apple-style dictation status capsule anchored under the menu-bar item.
///
/// Shows ONLY dictation status (`recording`, `transcribing`, `inserting`, `failed`),
/// never recognized text preview. Designed with a Liquid Glass aesthetic (hairline border,
/// subtle blur, native shadow) and fluid droplet emergence animation physically flowing
/// downward out of the menu bar item.
/// Includes VoiceOver accessibility support.
final class DictationIndicator {

    private let panel: NSPanel
    private let blur: NSVisualEffectView
    private let contentStack: NSStackView
    private let iconView: NSImageView
    private let statusLabel: NSTextField
    private let rightContainer: NSView
    private let spinner: NSProgressIndicator
    private let waveformContainer: NSView
    private let bars: [CALayer]
    private let barCount = 5

    private var currentStatus: AppStatus = .idle
    private var smoothedLevel: CGFloat = 0
    private var lastTargetPoint: NSPoint = .zero
    private var isEmerging = false

    init() {
        let defaultWidth: CGFloat = 180
        let height: CGFloat = 40

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: defaultWidth, height: height))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        // Liquid Glass hairline border (15% white, 0.75pt)
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        blur.layer?.borderWidth = 0.75
        blur.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = blur

        contentStack = NSStackView()
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(contentStack)

        // Left Icon: tinted to match menu bar status color
        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .systemCyan
        contentStack.addArrangedSubview(iconView)

        // Center Label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        contentStack.addArrangedSubview(statusLabel)

        // Right Symmetrical Container (Waveform during recording, Spinner during recognizing)
        rightContainer = NSView()
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(rightContainer)

        waveformContainer = NSView()
        waveformContainer.translatesAutoresizingMaskIntoConstraints = false
        waveformContainer.wantsLayer = true
        rightContainer.addSubview(waveformContainer)

        spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        rightContainer.addSubview(spinner)

        let barW: CGFloat = 2.5
        let barGap: CGFloat = 2.5
        let totalWaveW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap // 22.5 pt

        var createdBars: [CALayer] = []
        for i in 0..<barCount {
            let bar = CALayer()
            // Brand signature blue / electric cyan: permanently blue, zero green flash
            bar.backgroundColor = NSColor.systemCyan.cgColor
            bar.cornerRadius = 1.25
            let x = CGFloat(i) * (barW + barGap)
            bar.frame = CGRect(x: x, y: 11, width: barW, height: 4)
            waveformContainer.layer?.addSublayer(bar)
            createdBars.append(bar)
        }
        bars = createdBars

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            rightContainer.widthAnchor.constraint(equalToConstant: totalWaveW),
            rightContainer.heightAnchor.constraint(equalToConstant: 26),

            waveformContainer.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            waveformContainer.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            waveformContainer.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            waveformContainer.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),

            spinner.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])

        updateAccessibility(status: .idle)
    }

    // MARK: Public API

    /// Update status capsule state (icon, label, spinner, waveform visibility).
    func setStatus(_ status: AppStatus) {
        setStatus(status, message: nil)
    }

    /// Update status capsule with optional human-readable message.
    func setStatus(_ status: AppStatus, message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentStatus = status
            self.statusLabel.stringValue = message ?? status.menuLabel

            // Icon matches exact menu bar status color & symbol
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            if let img = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.menuLabel)?
                .withSymbolConfiguration(config) {
                self.iconView.image = img
                self.iconView.contentTintColor = status.color
            }

            let isListening = (status == .listening)
            let isRecognizing = (status == .recognizing)

            // Waveform active only while listening
            self.waveformContainer.isHidden = !isListening
            if !isListening {
                self.resetWaveform()
            }

            // Spinner active on the right only during recognition ("Обработка")
            if isRecognizing {
                self.spinner.isHidden = false
                self.spinner.startAnimation(nil)
            } else {
                self.spinner.stopAnimation(nil)
                self.spinner.isHidden = true
            }

            // Right container visibility: shown for listening & recognizing to maintain balance,
            // hidden for inserting / failed so icon and text remain centered.
            self.rightContainer.isHidden = (!isListening && !isRecognizing)

            self.updateAccessibility(status: status)

            if self.panel.isVisible && !self.isEmerging {
                self.recalculateFrame(animated: true)
            }
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

    /// Show capsule anchored under status item button with fluid liquid droplet emergence animation.
    func show(near point: NSPoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastTargetPoint = point
            self.showLiquidDroplet()
        }
    }

    /// Hide capsule with fluid upward liquid retraction into the menu bar.
    func hide() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hideLiquidDroplet()
        }
    }

    // MARK: - Fluid Liquid Droplet Emergence Animation

    private func calculateTargetFrame() -> NSRect {
        let labelWidth = statusLabel.intrinsicContentSize.width
        let rightWidth: CGFloat = rightContainer.isHidden ? 0 : 28
        let totalContentWidth = 16 + 8 + labelWidth + (rightContainer.isHidden ? 0 : (8 + rightWidth)) + 36
        let width: CGFloat = max(180, ceil(totalContentWidth))
        let height: CGFloat = 40

        // In macOS, the primary display is always NSScreen.screens.first (origin (0, 0) with main menubar)
        guard let mainScreen = NSScreen.screens.first else {
            return NSRect(x: 200, y: 200, width: width, height: height)
        }

        let point = lastTargetPoint
        let targetX: CGFloat
        if point.x > 0 && NSMouseInRect(point, mainScreen.frame, false) {
            // Anchor directly under status item on the primary macOS screen
            let minX = mainScreen.visibleFrame.minX + 10
            let maxX = mainScreen.visibleFrame.maxX - width - 10
            targetX = min(max(point.x - width / 2, minX), maxX)
        } else {
            // Center horizontally under the primary menu bar
            targetX = mainScreen.visibleFrame.midX - width / 2
        }

        let targetY = mainScreen.visibleFrame.maxY - height - 6
        return NSRect(x: targetX, y: targetY, width: width, height: height)
    }

    private func showLiquidDroplet() {
        let targetFrame = calculateTargetFrame()
        panel.setFrame(targetFrame, display: true)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            blur.layer?.transform = CATransform3DIdentity
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
            return
        }

        isEmerging = true

        // Fluid emergence: capsule drops down out of the menu bar, stretching and settling
        blur.layer?.transform = CATransform3DConcat(
            CATransform3DMakeTranslation(0, 14, 0),
            CATransform3DMakeScale(0.85, 0.65, 1.0)
        )
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            self.panel.animator().alphaValue = 1.0

            let animTransform = CABasicAnimation(keyPath: "transform")
            animTransform.fromValue = blur.layer?.transform
            animTransform.toValue = CATransform3DIdentity
            animTransform.duration = 0.28
            animTransform.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            blur.layer?.add(animTransform, forKey: "fluidEmergence")
            blur.layer?.transform = CATransform3DIdentity
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isEmerging = false
        })
    }

    private func hideLiquidDroplet() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0.0

            let animTransform = CABasicAnimation(keyPath: "transform")
            animTransform.fromValue = CATransform3DIdentity
            animTransform.toValue = CATransform3DConcat(
                CATransform3DMakeTranslation(0, 12, 0),
                CATransform3DMakeScale(0.85, 0.65, 1.0)
            )
            animTransform.duration = 0.20
            animTransform.timingFunction = CAMediaTimingFunction(name: .easeIn)
            blur.layer?.add(animTransform, forKey: "fluidRetract")
            blur.layer?.transform = animTransform.toValue as? CATransform3D ?? CATransform3DIdentity
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.blur.layer?.transform = CATransform3DIdentity
        })
    }

    private func recalculateFrame(animated: Bool) {
        guard !isEmerging else { return }
        let targetFrame = calculateTargetFrame()
        guard panel.frame != targetFrame else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion || !animated {
            panel.setFrame(targetFrame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    // MARK: - Waveform & Accessibility

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
            // Brand cyan permanently: zero green artifact
            bar.backgroundColor = NSColor.systemCyan.cgColor
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
            bar.backgroundColor = NSColor.systemCyan.cgColor
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
