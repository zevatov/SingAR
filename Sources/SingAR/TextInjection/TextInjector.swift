import AppKit

/// Pastes text into the focused app via the pasteboard + a synthesized Cmd+V.
/// Robust across all apps and scripts; handles Cyrillic without IME quirks.
/// TODO(M1): save/restore the user's pasteboard around the paste.
final class TextInjector {

    private let pasteboard = NSPasteboard.general

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // TODO(M1): preserve existing pasteboard contents, set string, post Cmd+V,
        // then restore. For now, a plain set + paste.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postPaste()
    }

    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)  // Cmd
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)  // V
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }
}
