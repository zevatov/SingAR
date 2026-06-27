import AppKit

/// Global hotkey via a CGEventTap. Replaces Apple dictation's Fn/Globe trigger:
/// disable Apple dictation (System Settings → Keyboard), then SingAR binds the
/// same key for hold-to-talk (default) or toggle mode.
///
/// TODO(M2): install an event tap on .keyDown/.flagsChanged, detect the chosen
/// trigger, honour Esc to cancel, and call onActivate/onDeactivate.
final class HotkeyManager {

    private let onActivate: () -> Void
    private let onDeactivate: () -> Void

    init(onActivate: @escaping () -> Void, onDeactivate: @escaping () -> Void) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
    }

    func install() {
        // TODO(M2): CGEvent.tapCreate + addToRunLoop. Requires Accessibility &
        // Input Monitoring permissions; surface a guidance prompt if missing.
    }

    func uninstall() {
        // TODO(M2): disable + remove the tap.
    }
}
