import AppKit

/// Global hotkey via NSEvent global monitor + CGEventSource polling fallback.
/// On macOS 26 (Tahoe), CGEventTap silently stops receiving events even with
/// Input Monitoring granted; NSEvent.addGlobalMonitorForEvents is the reliable
/// path for observing modifier-key presses system-wide.
///
/// Hold the trigger key to talk, release to stop (toggle mode: press to flip).
/// Esc cancels an active session. Requires Accessibility permission.
final class HotkeyManager {

    // MARK: Этап 3: pure seam для сторон модификаторов (offline unit-tested)

    /// Classifies a flagsChanged/keyCode event against the configured trigger.
    ///
    /// Ограничение (документировано): определение стороны опирается на
    /// `NSEvent.keyCode` из global/local monitor. На macOS 26 (Tahoe)
    /// `CGEventTap` ненадёжен (см. комментарий к классу), поэтому
    /// CGEvent-flags/sourceStateID путь не используется; NSEvent корректно
    /// различает стороны через keycode правого (61) и левого (58) Option.
    /// Если будущая macOS перестанет доставлять корректный keyCode в
    /// flagsChanged — это место единственная точка правды (`isTriggerEvent`).
    enum TriggerKey: Equatable {
        case leftOption
        case rightOption
        case fnGlobe
        case other

        static let leftOptionKeyCode: UInt16 = 58
        static let rightOptionKeyCode: UInt16 = 61
        static let fnGlobeKeyCode: UInt16 = 63

        static func classify(keyCode: UInt16) -> TriggerKey {
            switch keyCode {
            case leftOptionKeyCode:  return .leftOption
            case rightOptionKeyCode: return .rightOption
            case fnGlobeKeyCode:     return .fnGlobe
            default:                 return .other
            }
        }

        static func isLeftOption(keyCode: UInt16) -> Bool {
            classify(keyCode: keyCode) == .leftOption
        }

        static func isRightOption(keyCode: UInt16) -> Bool {
            classify(keyCode: keyCode) == .rightOption
        }

        /// True только для ТОЧНОГО ключа, выбранного в настройках: в режиме
        /// Right-Option левый Option (58) НЕ может стартовать/остановить
        /// диктовку (регресс-требование Этапа 3).
        static func isTriggerEvent(keyCode: UInt16, hotkey: HotkeyChoice) -> Bool {
            switch hotkey {
            case .rightOption: return keyCode == rightOptionKeyCode
            case .fnOrGlobe:   return keyCode == fnGlobeKeyCode
            }
        }
    }

    private let onActivate: () -> Void
    private let onDeactivate: () -> Void
    private let onCancel: () -> Void
    /// Extra gate: Esc must also cancel while finalization is still in flight.
    var canCancel: () -> Bool = { false }
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

    init(onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onCancel = onCancel
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

        // Esc cancels an active dictation OR its still-running finalization.
        if keyCode == UInt16(escKeyCode) && event.type == .keyDown && (dictating || canCancel()) {
            NSLog("[SingAR] Esc pressed — cancelling dictation/processing")
            dictating = false
            onCancel()
            return
        }

        // Only flagsChanged events carry modifier-key presses/releases.
        guard event.type == .flagsChanged else {
            return
        }
        // Этап 3: side-exact guard через pure seam — левый Option не проходит
        // в режиме Right-Option (keyCode 58 ≠ 61), Fn/Globe не ловит Option.
        guard TriggerKey.isTriggerEvent(keyCode: keyCode, hotkey: settings.hotkey) else { return }

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
