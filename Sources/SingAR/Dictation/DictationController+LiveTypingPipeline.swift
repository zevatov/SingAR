import Foundation

// MARK: - Этап 3: LiveTypingPipeline
//
// Живой ввод во время записи: приём partials от движков, guard'ы
// verify/owned-tail, дифф lastLiveText→newText (common prefix), пакетная
// инъекция через `TextInjector`, гашение при focus-shift (Option Б) и
// атомарное применение финального текста. Код перенесён 1:1.
extension DictationController {

    // MARK: Real-time Live Typing Engine

    func handleLivePartial(_ newText: String) {
        guard isDictating, showsLiveHints, !liveTypingSuppressedDueToFocusShift else { return }
        // Gate 1.5 + PRE-DMG-FIX: live keystrokes/backspaces require THIS
        // session's captured, re-verified target right now (PID + semantic
        // identity, trusted AX, no secure input). Foreign/unverifiable ⇒ skip.
        let gen = sessionGeneration
        if let denial = focusTargetGate.canMutate(generation: gen) {
            if !settings.stopOnFocusLoss && !liveTypingSuppressedDueToFocusShift {
                suppressLiveTypingDueToFocusShift()
            }
            NSLog("[SingAR] live partial skipped: target not verifiable (\(denial.rawValue))")
            return
        }
        // Guard against user-typed interference inside the owned window: if
        // the editor exposes a value, the session's draft must still be its
        // tail before erasing/retyping anything.
        if let tailDenial = focusTargetGate.verifiedAppendTail(generation: gen, ownedText: lastLiveText) {
            NSLog("[SingAR] live partial skipped: owned tail not verifiable (\(tailDenial.rawValue))")
            return
        }
        let cleaned = processed(newText)
        guard !cleaned.isEmpty, cleaned != lastLiveText else { return }

        // Compute common prefix to minimize backspaces
        let oldChars = Array(lastLiveText)
        let newChars = Array(cleaned)

        var commonPrefixLength = 0
        while commonPrefixLength < oldChars.count &&
              commonPrefixLength < newChars.count {
            if oldChars[commonPrefixLength] == newChars[commonPrefixLength] {
                commonPrefixLength += 1
            } else if commonPrefixLength == 0 &&
                      oldChars[0].lowercased() == newChars[0].lowercased() {
                // Speech engine changed capitalization of word 0 (e.g. SFSpeech/Gemini):
                // preserve already-typed character to prevent erasing entire sentence!
                commonPrefixLength += 1
            } else {
                break
            }
        }

        let backspacesNeeded = oldChars.count - commonPrefixLength
        let charsToType = String(newChars[commonPrefixLength...])

        NSLog("[SingAR] ⚡️ Live typing partial: %@ (charsToType=\(charsToType.count), backspaces=\(backspacesNeeded))", AppLogger.redactedPreview(cleaned))

        // Этап 2: 35мс живая печать БЕЗ блокировки main — пакетно в фоне
        // (`backspaceThenType`: erase + settle-35мс + type одним FIFO-блоком).
        // Main свободен; `lastLiveText` обновляется оптимистично здесь же.
        if backspacesNeeded > 0 || !charsToType.isEmpty {
            injector.backspaceThenType(backspaces: backspacesNeeded, text: charsToType)
        }

        lastLiveText = cleaned
        hasLiveTyped = true
    }

    /// Option Б: when target window loses focus during multitasking mode (!stopOnFocusLoss),
    /// immediately suppress any future live typing to prevent lag/freezes, and attempt to
    /// erase any live draft already typed into the target editor.
    func suppressLiveTypingDueToFocusShift() {
        guard !liveTypingSuppressedDueToFocusShift else { return }
        liveTypingSuppressedDueToFocusShift = true
        AppLogger.shared.log("🪟 focus shifted in multitasking mode — suppressing live typing for remainder of session")
        if hasLiveTyped && !lastLiveText.isEmpty {
            let range = NSRange(location: 0, length: (lastLiveText as NSString).length)
            if focusTargetGate.replaceText(generation: sessionGeneration, range: range, with: "") {
                AppLogger.shared.log("🪟 live draft erased immediately via AX upon focus shift")
                lastLiveText = ""
                hasLiveTyped = false
            } else {
                AppLogger.shared.log("🪟 live draft preserved for atomic replace/paste upon session finish")
            }
        }
    }

    /// Guaranteed atomic application of polished text upon dictation finish.
    /// PRE-DMG-FIX: the erase is bounded by the caller's verified owned range
    /// (UTF-16 length equals the draft length in that proof), so backspaces
    /// can never cross outside the session-owned window.
    /// Этап 2: 35мс финал БЕЗ блокировки main — пакетно (`eraseThenInsert`:
    /// erase в фоне + settle-35мс в фоне + `insert` на main одним FIFO-блоком).
    /// Main свободен; `lastLiveText` обновляется оптимистично здесь же.
    func applyPolishedText(_ polished: String, ownedRange: NSRange) {
        guard !polished.isEmpty else { return }
        guard polished != lastLiveText else { return }

        // Mode 1 & 2: Try native AX atomic in-place replacement (0ms, 0 backspaces, 0 clipboard touch)
        if ownedRange.length > 0 && focusTargetGate.replaceText(generation: sessionGeneration, range: ownedRange, with: polished) {
            AppLogger.shared.log("⚡️ applyPolishedText: native AX atomic replace succeeded (0ms)")
            lastLiveText = polished
            return
        }

        // Safely erase exactly the verified owned window + paste (пакетно, main не блокируется):
        if ownedRange.length > 0 {
            injector.eraseThenInsert(eraseCount: ownedRange.length, text: polished)
        } else {
            // Atomically paste the clean polished text (zero character drops, zero race conditions)
            injector.insert(polished)
        }
        lastLiveText = polished
    }
}
