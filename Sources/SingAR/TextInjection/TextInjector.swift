import AppKit

/// Pastes text into the focused app via the pasteboard + a synthesized Cmd+V.
/// Robust across all apps and scripts; handles Cyrillic without IME quirks.
/// Preserves the user's existing pasteboard contents around the paste.
final class TextInjector {

    private let pasteboard = NSPasteboard.general

    func insert(_ text: String) {
        guard !text.isEmpty else { return }

        // Snapshot whatever the user currently has on the pasteboard.
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postPaste()

        // Restore the user's clipboard shortly after, once the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [savedItems] in
            self.pasteboard.clearContents()
            for dict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                self.pasteboard.writeObjects([item])
            }
        }
    }

    /// Insert text, replacing any current selection in the focused field first
    /// (Apple-dictation style: selected text is overwritten by the transcript).
    func insertReplacingSelection(_ text: String) {
        guard !text.isEmpty else { return }
        // Clear the selection with Delete, then paste. This replaces whatever
        // was highlighted without disturbing the surrounding text.
        postKey(virtualKey: 0x33, flags: []) // Delete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.insert(text)
        }
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

    /// Post a single key event with optional modifier flags.
    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
