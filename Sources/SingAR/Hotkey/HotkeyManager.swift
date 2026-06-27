import AppKit

/// Global hotkey via a CGEventTap. Replaces Apple dictation's Fn/Globe trigger.
///
/// Default trigger: **hold** the Fn/Globe key (keycode 63) to talk, release to
/// stop. In toggle mode, a press starts/stops dictation. Esc cancels an active
/// session. Requires Accessibility + Input Monitoring permissions.
final class HotkeyManager {

    private let onActivate: () -> Void
    private let onDeactivate: () -> Void
    private let settings = AppSettings.shared

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Fn/Globe keycode.
    private let fnKeyCode: CGKeyCode = 63
    /// Esc keycode.
    private let escKeyCode: CGKeyCode = 53

    private var isFnDown = false
    private var dictating = false

    init(onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
    }

    func install() {
        guard tap == nil else { return }
        guard ensurePermissions() else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[SingAR] failed to create CGEventTap (permissions?)")
            return
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tap = port
        runLoopSource = src
    }

    func uninstall() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        tap = nil
    }

    // MARK: Permission guidance

    private func ensurePermissions() -> Bool {
        // Input Monitoring / Accessibility are checked at the system level; if the
        // tap creation fails the user hasn't granted them. We surface guidance.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
        if !trusted {
            NSLog("[SingAR] Accessibility permission missing — dictation hotkey inactive.")
        }
        return true // attempt the tap regardless; it no-ops if untrusted.
    }

    // MARK: Event handling

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let type = event.type
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if keyCode == escKeyCode && dictating {
            // Esc cancels an active dictation.
            onDeactivate()
            dictating = false
            return Unmanaged.passUnretained(event)
        }

        guard keyCode == fnKeyCode else { return Unmanaged.passUnretained(event) }

        switch settings.mode {
        case .hold:
            // Hold-to-talk: key down starts, key up stops.
            let down = (type == .flagsChanged && !isFnDown) || type == .keyDown
            if down && !isFnDown {
                isFnDown = true
                if !dictating && settings.enabled {
                    dictating = true
                    onActivate()
                }
            } else if type == .keyUp || (type == .flagsChanged && isFnDown && !event.flags.contains(.maskSecondaryFn)) {
                // Heuristic release detection; refined once we pin the exact event.
                isFnDown = false
                if dictating {
                    dictating = false
                    onDeactivate()
                }
            }
        case .toggle:
            // Toggle: a single press flips dictation on/off.
            if type == .keyDown && !isFnDown {
                isFnDown = true
                dictating.toggle()
                if dictating { onActivate() } else { onDeactivate() }
            } else if type == .keyUp {
                isFnDown = false
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
