import AppKit

/// Floating overlay shown while dictating: displays the live partial transcript
/// and a waveform indicator, anchored below the menu bar. Appears instantly on
/// start, fades on finish. Mimics Apple dictation's inline bubble but richer.
final class DictationOverlay {

    private let panel: NSPanel
    private let textField: NSTextField
    private let glow: NSView

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        glow = NSView()
        glow.wantsLayer = true
        glow.layer?.cornerRadius = 14
        glow.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        glow.layer?.borderWidth = 1
        glow.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 15, weight: .medium)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.maximumNumberOfLines = 1
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isSelectable = false

        glow.addSubview(textField)
        panel.contentView = glow
    }

    /// Show anchored under the status item, near the top-right.
    func show(near point: NSPoint) {
        let w: CGFloat = 420, h: CGFloat = 56
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame: NSRect
        if let screen {
            let sw = screen.visibleFrame.width
            frame = NSRect(x: min(point.x - w + 24, sw - w - 12),
                           y: screen.visibleFrame.maxY - h - 8,
                           width: w, height: h)
        } else {
            frame = NSRect(x: point.x, y: point.y, width: w, height: h)
        }
        panel.setFrame(frame, display: true)

        textField.frame = NSRect(x: 16, y: 16, width: w - 32, height: 24)
        textField.stringValue = ""
        panel.orderFrontRegardless()
    }

    /// Update the visible partial transcript.
    func setTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.textField.stringValue = text.isEmpty ? "Слушаю…" : text
        }
    }

    /// Pulse the waveform glow (call on each audio chunk for a live feel).
    func pulse() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.glow.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.glow.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
            }
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.panel.orderOut(nil)
        }
    }
}
