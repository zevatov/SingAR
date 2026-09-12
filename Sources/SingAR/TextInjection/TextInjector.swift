import AppKit

/// Injects text into the focused app. Two modes:
///   - `typeText(_:)` — keystroke-by-keystroke via CGEvent (fast, live-typing feel)
///   - `insert(_:)` — pasteboard + Cmd+V (for final, multi-line, or non-ASCII)
/// Plus `backspace(count:)` to erase a previously-typed partial.
final class TextInjector {

    private let pasteboard = NSPasteboard.general

    private var pendingRestoreItem: DispatchWorkItem?
    private var lastInjectedText: String?

    /// Cancels any scheduled clipboard restore work item from prior insertions.
    func cancelPendingRestore() {
        pendingRestoreItem?.cancel()
        pendingRestoreItem = nil
    }

    /// Type a string character-by-character. Each char becomes a keyDown/keyUp
    /// pair, so the text appears live in the field as if the user typed it.
    func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            // Use the Unicode-aware key event path: post a keyDown with the
            // character attached. This handles Latin, Cyrillic, punctuation.
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            // Set the Unicode string on the keyDown event.
            var chars = Array(String(char).utf16)
            down?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(2000) // 2ms delay ensures characters are ordered in target app
        }
    }

    /// Press Backspace `count` times to erase previously-typed text (paced to avoid dropped events).
    func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        // 3ms delay ensures heavy Electron and native editors never drop backspaces
        let delayMicros: useconds_t = 3000
        // 0x33 = Delete/Backspace key code.
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(delayMicros)
        }
    }

    /// Paste text via the pasteboard + Cmd+V. Used for final results, multiline,
    /// or when typeText isn't suitable. Preserves the user's clipboard with
    /// zero-race changeCount validation and pending restore cancellation.
    func insert(_ text: String) {
        guard !text.isEmpty else { return }

        // Invalidate any previously pending clipboard restore so sessions don't collide
        cancelPendingRestore()

        // If the pasteboard currently holds our own previous insertion, do not
        // capture it as user clipboard content (prevents endless loop).
        let currentString = pasteboard.string(forType: .string)
        let isOurPreviousInjection = (lastInjectedText != nil && currentString == lastInjectedText)

        let savedItems: [[NSPasteboard.PasteboardType: Data]]
        if isOurPreviousInjection {
            savedItems = []
        } else {
            savedItems = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        dict[type] = data
                    }
                }
                return dict.isEmpty ? nil : dict
            } ?? []
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastInjectedText = text
        let expectedChangeCount = pasteboard.changeCount

        postPaste()

        // Extended 600ms grace period ensures heavy editors (VS Code, Electron, Obsidian)
        // have fully consumed Cmd+V before clipboard restoration starts.
        let restoreItem = DispatchWorkItem { [weak self, savedItems, expectedChangeCount] in
            guard let self else { return }
            // Verify user hasn't copied anything new during the paste window.
            guard self.pasteboard.changeCount == expectedChangeCount else {
                NSLog("[SingAR] Clipboard changeCount changed (%ld != %ld) — user copied new content, skipping restore",
                      self.pasteboard.changeCount, expectedChangeCount)
                return
            }
            guard !savedItems.isEmpty else { return }
            self.pasteboard.clearContents()
            for dict in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in dict {
                    item.setData(data, forType: type)
                }
                self.pasteboard.writeObjects([item])
            }
        }

        pendingRestoreItem = restoreItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: restoreItem)
    }

    /// Insert text, replacing any current selection first (Apple-dictation style).
    func insertReplacingSelection(_ text: String) {
        guard !text.isEmpty else { return }
        postKey(virtualKey: 0x33, flags: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.insert(text)
        }
    }

    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

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
