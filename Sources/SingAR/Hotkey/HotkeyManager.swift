import AppKit

/// Global hotkey via NSEvent global monitor + CGEventSource polling fallback.
/// On macOS 26 (Tahoe), CGEventTap silently stops receiving events even with
/// Input Monitoring granted; NSEvent.addGlobalMonitorForEvents is the reliable
/// path for observing modifier-key presses system-wide.
///
/// Hold the trigger key to talk, release to stop (toggle mode: press to flip).
/// Esc cancels an active session. Requires Accessibility permission.
final class HotkeyManager {

    private let onActivate: () -> Void
    private let onDeactivate: () -> Void
    private let settings = AppSettings.shared

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Trigger keycode — read from settings (Fn/Globe or right-Option).
    private var triggerKeyCode: CGKeyCode { settings.hotkey.keyCode }
    /// Esc keycode.
    private let escKeyCode: CGKeyCode = 53

    /// Was the trigger modifier flag set on the previous event? Track edge
    /// transitions (false→true = press, true→false = release).
    private var triggerFlagWasSet = false
    private var dictating = false

    init(onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
    }

    /// Force the toggle state back to "not dictating" without calling
    /// onDeactivate. Used when dictation was stopped elsewhere (focus lost) so
    /// the next trigger press cleanly starts a new session instead of being
    /// consumed by a stale toggle.
    func forceReset() {
        dictating = false
        triggerFlagWasSet = false
    }

    func install() {
        guard globalMonitor == nil else { return }
        ensurePermissions()

        // Global monitor: catches events when SingAR is NOT the frontmost app
        // (the normal dictation case — user is typing in another app).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }

        // Local monitor: catches events when SingAR IS frontmost (settings window,
        // onboarding) so the trigger still works there.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }

        NSLog("[SingAR] ✅ Hotkey monitors installed. Trigger keycode=\(triggerKeyCode) (\(settings.hotkey.rawValue)) mode=\(settings.mode.rawValue)")
    }

    func uninstall() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    // MARK: Permission guidance

    private func ensurePermissions() {
        // CHECK ONLY — do not trigger a system prompt here. The onboarding
        // window is the single place that requests permissions (and only when
        // not yet granted), so the user never sees duplicate TCC dialogs.
        let axTrusted = AXIsProcessTrusted()
        NSLog("[SingAR] permissions: Accessibility=\(axTrusted ? "GRANTED" : "MISSING")")
    }

    // MARK: Event handling

    private func handle(_ event: NSEvent) {
        let keyCode = event.keyCode

        // Esc cancels an active dictation.
        if keyCode == UInt16(escKeyCode) && event.type == .keyDown && dictating {
            NSLog("[SingAR] Esc pressed — cancelling dictation")
            onDeactivate()
            dictating = false
            return
        }

        // Only flagsChanged events carry modifier-key presses/releases.
        guard event.type == .flagsChanged else {
            return
        }
        guard keyCode == UInt16(triggerKeyCode) else { return }

        // Track the flag state per trigger kind.
        let flagSet: Bool
        if settings.hotkey == .fnOrGlobe {
            flagSet = event.modifierFlags.contains(.function)
        } else {
            flagSet = event.modifierFlags.contains(.option)
        }

        switch settings.mode {
        case .hold:
            if flagSet && !triggerFlagWasSet {
                NSLog("[SingAR] trigger DOWN — starting dictation")
                triggerFlagWasSet = true
                if !dictating && settings.enabled {
                    dictating = true
                    onActivate()
                }
            } else if !flagSet && triggerFlagWasSet {
                NSLog("[SingAR] trigger UP — stopping dictation")
                triggerFlagWasSet = false
                if dictating {
                    dictating = false
                    onDeactivate()
                }
            }
        case .toggle:
            if flagSet && !triggerFlagWasSet {
                triggerFlagWasSet = true
                dictating.toggle()
                NSLog("[SingAR] trigger press — dictating=\(dictating)")
                if dictating { onActivate() } else { onDeactivate() }
            } else if !flagSet && triggerFlagWasSet {
                triggerFlagWasSet = false
            }
        }
    }
}
