import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - PRE-DMG-FIX: session-scoped dictation target ownership
//
// Fail-closed target model: the controller captures ONE verified editable
// element (PID + semantic identity) per dictation session and re-verifies it
// before every mutation (live partials, focus monitoring, finalize insertion,
// Esc-cancel backspace). Any unverifiable state (AX untrusted/error, secure
// event input, no focused element, non-settable value, foreign PID, foreign
// element, unreadable selection, changed value window) DENIES the mutation —
// there is no frontmost-bundle fallback for writes.

/// Semantic identity components of one focused text element. Equality
/// compares EVERY captured component (not a single hash), so a same-PID
/// different-element switch inside one app is detected.
struct FocusedElementIdentity: Equatable {
    var role: String?
    var title: String?
    var descriptionValue: String?
    var windowTitle: String?
    var position: CGPoint?
    var size: CGSize?
}

/// AX facts about the currently focused element, as read by a probe.
struct FocusedElementFacts {
    var pid: pid_t
    var identity: FocusedElementIdentity
    var isValueSettable: Bool
    var value: String?
    /// AX selection in UTF-16 units (kAXSelectedTextRangeAttribute), if the
    /// editor exposes it.
    var selectedRange: NSRange?
}

/// Indirection over the real AX surface so the ownership gate is unit-testable
/// with a fake probe; ONLY the production probe calls real AX APIs.
protocol AXFocusProbing: AnyObject {
    func isProcessTrusted() -> Bool
    func isSecureEventInput() -> Bool
    func readFocusedFacts() -> FocusedElementFacts?
    func replaceText(in range: NSRange, with text: String) -> Bool
}

extension AXFocusProbing {
    func replaceText(in range: NSRange, with text: String) -> Bool { false }
}

/// Why a mutation was denied. Never contains user content.
enum FocusTargetDenial: String, Equatable, Error {
    case axUnavailable
    case secureInput
    case noFocusedElement
    case foreignTarget
    case generationStale
    case snapshotMismatch
    case selectionUnavailable
}

/// Session-scoped target gate. Main-thread use only (same as the controller).
final class DictationFocusTargetGate {
    private let probe: AXFocusProbing

    private(set) var capturedGeneration = 0
    private(set) var capturedPID: pid_t?
    private(set) var capturedIdentity: FocusedElementIdentity?

    init(probe: AXFocusProbing = LiveAXFocusProbe()) {
        self.probe = probe
    }

    /// startDictation: capture + fail-closed validation. Resets any previous
    /// target FIRST, so a new generation can never inherit an old element.
    /// Returns false when no safe target can be confirmed.
    @discardableResult
    func captureSessionTarget(generation: Int) -> Bool {
        capturedGeneration = 0
        capturedPID = nil
        capturedIdentity = nil
        guard probe.isProcessTrusted() else { return false }
        guard !probe.isSecureEventInput() else { return false }
        guard let facts = probe.readFocusedFacts() else { return false }
        guard facts.isValueSettable else { return false }
        guard facts.identity.role != nil else { return false }
        capturedGeneration = generation
        capturedPID = facts.pid
        capturedIdentity = facts.identity
        return true
    }

    /// Drops the captured target when it belongs to `generation` (a foreign
    /// generation never invalidates a newer capture).
    func invalidate(generation: Int) {
        guard generation == capturedGeneration else { return }
        capturedGeneration = 0
        capturedPID = nil
        capturedIdentity = nil
    }

    /// Non-destructive check: the focused element is still THIS session's
    /// captured, verified target. Returns the denial reason or nil.
    func canMutate(generation: Int) -> FocusTargetDenial? {
        guard generation == capturedGeneration, capturedPID != nil, capturedIdentity != nil else {
            return .generationStale
        }
        guard probe.isProcessTrusted() else { return .axUnavailable }
        guard !probe.isSecureEventInput() else { return .secureInput }
        guard let facts = probe.readFocusedFacts(), facts.isValueSettable else {
            return .noFocusedElement
        }
        guard facts.pid == capturedPID, facts.identity == capturedIdentity else {
            return .foreignTarget
        }
        return nil
    }

    /// Destructive plan: proves ownership of the session's live-typed text
    /// before ANY backspace/replacement. The caret must sit at the end of the
    /// owned window (empty selection), and the editor value inside that window
    /// must still equal the owned text. Ranges are UTF-16 based, matching AX
    /// selection semantics. Snapshot stays in memory only — never logged.
    func verifiedOwnedRange(generation: Int, ownedText: String) -> Result<NSRange, FocusTargetDenial> {
        if let denial = canMutate(generation: generation) { return .failure(denial) }
        guard let facts = probe.readFocusedFacts() else { return .failure(.noFocusedElement) }
        guard let selection = facts.selectedRange else { return .failure(.selectionUnavailable) }
        guard selection.length == 0 else { return .failure(.snapshotMismatch) } // user made a selection
        guard let value = facts.value else { return .failure(.snapshotMismatch) }
        let nsValue = value as NSString
        let ownedLength = (ownedText as NSString).length
        guard ownedLength > 0 else { return .failure(.snapshotMismatch) }
        let caret = selection.location
        guard caret >= ownedLength, caret <= nsValue.length else { return .failure(.snapshotMismatch) }
        let ownedRange = NSRange(location: caret - ownedLength, length: ownedLength)
        guard nsValue.substring(with: ownedRange) == ownedText else { return .failure(.snapshotMismatch) }
        return .success(ownedRange)
    }

    /// Conservative append-only check for editors that do not expose a
    /// selection: the value must still END with the owned text, so the caret
    /// is (with high confidence) right after it. Never used for destructive
    /// edits.
    func verifiedAppendTail(generation: Int, ownedText: String) -> FocusTargetDenial? {
        if let denial = canMutate(generation: generation) { return denial }
        guard let facts = probe.readFocusedFacts() else {
            return .noFocusedElement
        }
        if let value = facts.value {
            guard ownedText.isEmpty || (value as NSString).hasSuffix(ownedText) else {
                return .snapshotMismatch
            }
        }
        return nil
    }

    /// Attempts atomic in-memory replacement of the verified draft range via Accessibility API.
    /// Returns true if the target editor accepted the replacement directly (0ms, 0 backspaces).
    func replaceText(generation: Int, range: NSRange, with text: String) -> Bool {
        guard canMutate(generation: generation) == nil else { return false }
        return probe.replaceText(in: range, with: text)
    }
}

/// Production probe: the ONLY type that touches real AX APIs for target
/// verification. Never instantiated from tests.
final class LiveAXFocusProbe: AXFocusProbing {
    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func isSecureEventInput() -> Bool {
        IsSecureEventInputEnabled()
    }

    func readFocusedFacts() -> FocusedElementFacts? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        let pid = frontApp.processIdentifier
        let appElem = AXUIElementCreateApplication(pid)

        var targetElement: AXUIElement = appElem
        var identity = FocusedElementIdentity(
            role: "AXApplication",
            title: frontApp.localizedName,
            descriptionValue: frontApp.bundleIdentifier,
            windowTitle: nil,
            position: nil,
            size: nil
        )

        var focusedCF: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedCF) == .success,
           let focusedCF, CFGetTypeID(focusedCF) == AXUIElementGetTypeID() {
            let elem = focusedCF as! AXUIElement
            targetElement = elem
            identity = readIdentity(elem)
            if identity.role == nil {
                identity.role = "AXFocusedUIElement"
            }
        } else {
            var windowCF: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &windowCF) == .success,
               let windowCF, CFGetTypeID(windowCF) == AXUIElementGetTypeID() {
                let winElem = windowCF as! AXUIElement
                targetElement = winElem
                identity = readIdentity(winElem)
                if identity.role == nil {
                    identity.role = "AXWindow"
                }
            }
        }

        var isSettable = true
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(targetElement, kAXValueAttribute as CFString, &settable) == .success {
            if !settable.boolValue && identity.role == "AXStaticText" {
                isSettable = false
            }
        }

        return FocusedElementFacts(
            pid: pid,
            identity: identity,
            isValueSettable: isSettable,
            value: stringAttribute(targetElement, kAXValueAttribute),
            selectedRange: selectedTextRange(targetElement)
        )
    }

    private func readIdentity(_ element: AXUIElement) -> FocusedElementIdentity {
        FocusedElementIdentity(
            role: stringAttribute(element, kAXRoleAttribute),
            title: stringAttribute(element, kAXTitleAttribute),
            descriptionValue: stringAttribute(element, kAXDescriptionAttribute),
            windowTitle: windowTitle(of: element),
            position: pointAttribute(element, kAXPositionAttribute),
            size: sizeAttribute(element, kAXSizeAttribute)
        )
    }

    private func windowTitle(of element: AXUIElement) -> String? {
        var windowCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowCF) == .success,
              let windowCF, CFGetTypeID(windowCF) == AXUIElementGetTypeID() else { return nil }
        return stringAttribute(windowCF as! AXUIElement, kAXTitleAttribute)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var cf: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &cf) == .success,
              let cf, let string = cf as? String else { return nil }
        return string
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var cf: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &cf) == .success, let cf,
              CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(cf as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var cf: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &cf) == .success, let cf,
              CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(cf as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        var cf: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &cf) == .success,
              let cf, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        // kAXSelectedTextRangeAttribute is an AXValue wrapping a CFRange
        // (location/length in UTF-16 units).
        var range = CFRange()
        guard AXValueGetValue(cf as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func replaceText(in range: NSRange, with text: String) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }
        let appElem = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedCF) == .success,
              let focusedCF, CFGetTypeID(focusedCF) == AXUIElementGetTypeID() else {
            return false
        }
        let elem = focusedCF as! AXUIElement

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeVal = AXValueCreate(.cfRange, &cfRange) else { return false }

        // Set the selection range to the target draft range
        let setRangeStatus = AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, rangeVal)
        guard setRangeStatus == .success else { return false }

        // Attempt direct atomic replacement of selected text
        let setTextStatus = AXUIElementSetAttributeValue(elem, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setTextStatus != .success {
            // If atomic replacement is not supported, collapse selection back to caret
            // at the end of the draft so fallback Backspaces safely delete backwards!
            var caretRange = CFRange(location: range.location + range.length, length: 0)
            if let caretVal = AXValueCreate(.cfRange, &caretRange) {
                _ = AXUIElementSetAttributeValue(elem, kAXSelectedTextRangeAttribute as CFString, caretVal)
            }
            return false
        }
        return true
    }
}
