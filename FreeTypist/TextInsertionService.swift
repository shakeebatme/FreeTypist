import AppKit
import ApplicationServices

/// How an accepted suggestion got in — or that it did not.
///
/// The distinction matters to the caller, not just as a diagnostic: an
/// Accessibility write is a synchronous round trip, so the field is already up
/// to date when `apply` returns, while synthesized keystrokes are posted and
/// forgotten and arrive milliseconds later.
enum InsertionOutcome {
    case accessibility
    case keyboard
    case failed

    var succeeded: Bool { self != .failed }

    /// Whether the field must be allowed to settle before it is read back.
    var isDeferred: Bool { self == .keyboard }
}

/// Writes an accepted suggestion into whichever app owns the caret.
///
/// Accessibility is tried first because it is atomic and invisible to undo
/// stacks; synthesized keystrokes are the fallback for apps (notably Electron
/// and some web editors) that expose text read-only.
@MainActor
final class TextInsertionService {
    private let deleteKeyCode: CGKeyCode = 51
    private let reader: FocusedTextReader

    /// How long to let posted keystrokes arrive before giving up on them.
    /// Generous: a local app usually takes a single-digit number of
    /// milliseconds, and the cost of waiting is paid only on the fallback path.
    private let settleTimeout: TimeInterval = 0.25
    /// How long to wait to be *told* the text changed before looking anyway.
    /// Short, because it is a floor rather than an interval: an app that posts
    /// AX notifications wakes us far sooner, and one that posts none degrades to
    /// polling at this rate.
    private let settleWake = Duration.milliseconds(12)

    /// Set by `AppModel`. Optional because insertion must keep working when the
    /// focused app reports nothing.
    weak var changes: AXChangeObserver?

    init(reader: FocusedTextReader) {
        self.reader = reader
    }

    @discardableResult
    func apply(_ suggestion: Suggestion, to element: AXUIElement?) -> InsertionOutcome {
        guard !suggestion.isEmpty else { return .failed }
        let target = element ?? AX.element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as String)
        guard let target else { return typeWithKeyboard(suggestion) ? .keyboard : .failed }

        // The return code is not evidence. Safari reports `AXSelectedText` as
        // settable, answers `.success`, and changes nothing — measured against a
        // live `<textarea>`, where the value was byte-identical before and
        // after. Trusting it loses the completion silently *and* leaves the
        // suggestion cleared, so the next Tab reaches the page and moves focus
        // to the next field. That is how this arrived as a bug report.
        let attempt = applyViaAccessibility(suggestion, to: target)
        if attempt.succeeded, landed(suggestion, in: target) { return .accessibility }

        // If Accessibility already widened the selection over the text being
        // replaced, typing alone overwrites it. Sending backspaces as well would
        // delete the selection *and* that many more characters. Re-read rather
        // than trusting `attempt`, for the same reason as above.
        return typeWithKeyboard(suggestion, skipDeletions: selectionIsExtended(target))
            ? .keyboard : .failed
    }

    /// Waits for synthesized keystrokes to reach the field, and reports whether
    /// they ever did.
    ///
    /// `CGEvent.post` is fire-and-forget: it returns long before the target app
    /// has handled the event, so the field still reads exactly as it did before
    /// the insertion. A caller that re-reads immediately gets a stale caret to
    /// draw at and a stale signature to compare against — and the next poll then
    /// sees a change it was not expecting and wipes the suggestion that was just
    /// re-anchored. In Safari that is what let the second Tab through to the
    /// page, where it moved focus to the next field.
    ///
    /// An Accessibility write needs none of this: it is a synchronous round trip
    /// and is already visible when `apply` returns.
    func awaitInsertion(of suggestion: Suggestion, in element: AXUIElement?) async -> Bool {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while true {
            if landed(suggestion, in: element) { return true }
            guard Date() < deadline else { return false }
            // Prefer being told. `nextChange` returns as soon as the app reports
            // the field changed, so the usual case is one wakeup rather than a
            // run of pointless re-reads; the timeout keeps apps that report
            // nothing working exactly as they did before.
            if let changes {
                _ = await changes.nextChange(within: settleWake)
            } else {
                try? await Task.sleep(for: settleWake)
            }
        }
    }

    /// Did the text actually arrive? Re-reads the field and looks for the
    /// inserted text immediately before the caret.
    ///
    /// Returns true when the field cannot be read at all: an unreadable field
    /// gives no grounds to type the text a second time, and a double insertion
    /// is worse than a missed one.
    ///
    /// A correction is the exception, and has to be, because it is the one case
    /// that manufactures the very state the reader refuses. It widens the
    /// selection over the word being replaced before writing, and a write that
    /// landed collapses that selection again — so one still open afterwards is
    /// positive evidence the app took the range and dropped the text. That is
    /// exactly what Safari does, and without this the fail-open above turned a
    /// silent refusal into a reported success: the keyboard fallback was
    /// skipped, the user was left with their own word selected and nothing
    /// inserted, and `noteInsertion` cleared the failure count, so the
    /// stand-down built for this app could never trip on a correction.
    ///
    /// Answering "no" here cannot double-insert. The keyboard fallback skips its
    /// backspaces for the same open selection and types over it, so a retry
    /// against a selection that somehow did hold the new text simply writes the
    /// same text in its place.
    private func landed(_ suggestion: Suggestion, in element: AXUIElement?) -> Bool {
        if suggestion.isCorrection, let element, selectionIsExtended(element) {
            return false
        }
        guard let now = reader.readFocusedText() else { return true }
        let before = now.textBeforeCursor
        if before.hasSuffix(suggestion.text) { return true }
        // Some fields normalise the whitespace around an insertion.
        let expected = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return true }
        return before.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(expected)
    }

    private func selectionIsExtended(_ element: AXUIElement) -> Bool {
        guard let range = AX.range(element, kAXSelectedTextRangeAttribute as String) else {
            return false
        }
        return range.length > 0
    }

    // MARK: - Accessibility

    private func applyViaAccessibility(
        _ suggestion: Suggestion,
        to element: AXUIElement
    ) -> (succeeded: Bool, selectionExtended: Bool) {
        var selectionExtended = false

        // For a correction, extend the selection back over the text being
        // replaced so a single write swaps it out.
        if suggestion.isCorrection {
            guard let caret = AX.range(element, kAXSelectedTextRangeAttribute as String) else {
                return (false, false)
            }
            // An Accessibility range is UTF-16, which is not what a backspace
            // counts — see `typeWithKeyboard` below for the other half.
            let length = suggestion.replacedRangeLength
            let start = caret.location - length
            guard start >= 0 else { return (false, false) }
            let replacement = CFRange(location: start, length: length)
            guard let value = AX.axValue(for: replacement) else { return (false, false) }
            guard AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, value
            ) == .success else { return (false, false) }
            selectionExtended = true
        }

        let wrote = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            suggestion.text as CFTypeRef
        ) == .success
        return (wrote, selectionExtended)
    }

    // MARK: - Synthesized keystrokes

    private func typeWithKeyboard(_ suggestion: Suggestion, skipDeletions: Bool = false) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Key presses, not UTF-16 units: one backspace removes one character
        // however many code units it took to store.
        let deletions = skipDeletions ? 0 : suggestion.replacedCharacterCount
        for _ in 0..<deletions {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)
            else { return false }
            SyntheticEvent.stamp(down)
            SyntheticEvent.stamp(up)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }

        var utf16 = Array(suggestion.text.utf16)
        guard !utf16.isEmpty else { return true }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        // After the string, not before: stamping clears the flags, and nothing
        // between here and `post` may put one back.
        SyntheticEvent.stamp(down)
        SyntheticEvent.stamp(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
