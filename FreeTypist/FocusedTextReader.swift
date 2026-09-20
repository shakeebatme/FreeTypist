import AppKit
import ApplicationServices

/// A snapshot of the text field that currently has keyboard focus, anywhere in
/// the system.
struct FocusedTextContext {
    let element: AXUIElement
    let bundleIdentifier: String?
    /// Display name of the owning app, for prompt framing ("Slack").
    let appName: String?
    let textBeforeCursor: String
    let textAfterCursor: String
    /// Caret bounds already converted to AppKit screen coordinates.
    let caretRect: CGRect?
    let selectedRange: CFRange
    /// Typography of the text at the caret, so a suggestion can be drawn inline
    /// in the target app's own font rather than in ours.
    let caretFont: NSFont?
    let caretTextColor: NSColor?
    /// True when this element was read through the WebKit text-marker API, in
    /// which case `selectedRange` is a derived character count rather than
    /// something the app will accept back.
    let usesTextMarkers: Bool

    /// Identity of the editing state. When this is unchanged there is nothing
    /// new to suggest, so the expensive path can be skipped entirely.
    var signature: String {
        "\(bundleIdentifier ?? "?")|\(selectedRange.location)|\(selectedRange.length)|\(textBeforeCursor.count)|\(textBeforeCursor.suffix(80))"
    }
}

@MainActor
final class FocusedTextReader {
    /// How much context to hand the model. Enough for a paragraph of intent,
    /// bounded so a large document cannot stall a read.
    private let maxContextBefore = 1_200
    /// Enough to carry the top of a quoted email, which is what sits after the
    /// caret in a reply and is the context that decides the suggestion.
    private let maxContextAfter = 800
    /// Above this, read a window around the caret instead of the whole value.
    private let windowedReadThreshold = 8_000

    private let systemWide = AXUIElementCreateSystemWide()

    init() {
        AX.configureMessagingTimeout(0.35)
    }

    func focusedElement() -> AXUIElement? {
        if let element = AX.element(systemWide, kAXFocusedUIElementAttribute as String) {
            return element
        }
        // Observed on macOS 27: the system-wide element intermittently answers
        // kAXErrorCannotComplete (-25204) even while permission is granted and
        // the frontmost app answers the identical query fine. Without this
        // fallback the app looks completely dead.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return AX.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as String)
    }

    /// The most recent app refused for lack of accessibility support, so the
    /// settings window can say why rather than leaving the user guessing.
    private(set) var lastLimitation: (bundleID: String, limitation: AppCompatibility.Limitation)?

    func readFocusedText() -> FocusedTextContext? {
        // Secure input is on somewhere, so a password is being collected and it
        // may well be the field under the caret. Refuse before touching
        // Accessibility at all: the subrole check further down only sees
        // AppKit's own secure fields, and the cases that matter most — a web
        // login form, an Electron password box, a terminal at a `sudo` prompt —
        // carry no subrole while turning secure input on.
        //
        // The reason for silence is the system state rather than this app, so
        // the last incompatible app's explanation must not be left standing:
        // `CompletionCoordinator` puts `lastLimitation` straight into the
        // status line, and it has its own sentence for this.
        if SecureInput.isActive {
            lastLimitation = nil
            return nil
        }

        guard let element = focusedElement() else { return nil }

        // One lookup, used four times below. `NSRunningApplication` is a real
        // process query and this runs on every fast pass.
        let app = runningApp(of: element)

        // Apps that cannot support inline completion at all: stop before
        // spending any AX round trips on them, and remember why.
        //
        // Settled here rather than on the way out. Every `return nil` below is a
        // *different* reason for silence — a password field, a live selection,
        // an app that answers nothing — and none of them should leave the last
        // incompatible app's explanation standing, because the caller puts it
        // straight into the status line. That is how "Ghostty doesn't expose
        // caret position." stayed on screen while the user was typing somewhere
        // else entirely.
        if let bundleID = app?.bundleIdentifier,
           let limitation = AppCompatibility.limitation(for: bundleID) {
            lastLimitation = (bundleID, limitation)
            return nil
        }
        lastLimitation = nil

        // Never read or suggest into a password field.
        if let subrole = AX.string(element, kAXSubroleAttribute as String),
           subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }

        // The presence of a selected-text range is the reliable signal that this
        // is an editable text control, across AppKit, most web areas and
        // Electron. WebKit's rich-text areas are the exception and are read
        // through markers instead.
        guard let selectedRange = AX.range(element, kAXSelectedTextRangeAttribute as String) else {
            return readViaTextMarkers(element, app: app)
        }
        // A non-empty selection means the user is selecting, not typing.
        guard selectedRange.length == 0 else { return nil }

        guard let (before, after) = readText(element, caret: selectedRange.location) else {
            return nil
        }

        var style = typography(element, caret: selectedRange.location)

        // Terminals expose no AXFont at all — Terminal.app's attribute list has
        // no attributed-string support — so the fallback would be the
        // proportional system font, visibly wrong against monospaced output.
        if style.font == nil, TerminalContext.isTerminal(app?.bundleIdentifier) {
            let caret = caretRect(
                element,
                caret: selectedRange.location,
                precededByNewline: before.last?.isNewline ?? true
            )
            let size = max(11, (caret?.height ?? 16) * 0.78)
            style.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        return FocusedTextContext(
            element: element,
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName,
            textBeforeCursor: before,
            textAfterCursor: after,
            caretRect: caretRect(
                element,
                caret: selectedRange.location,
                precededByNewline: before.last?.isNewline ?? true
            ),
            selectedRange: selectedRange,
            caretFont: style.font,
            caretTextColor: style.color,
            usesTextMarkers: false
        )
    }

    /// WebKit rich-text areas (Mail's compose body, Notes) expose no character
    /// ranges at all. See `TextMarkers`.
    private func readViaTextMarkers(
        _ element: AXUIElement,
        app: NSRunningApplication?
    ) -> FocusedTextContext? {
        guard let reading = TextMarkers.read(
            element, maxBefore: maxContextBefore, maxAfter: maxContextAfter
        ) else { return nil }

        return FocusedTextContext(
            element: element,
            bundleIdentifier: app?.bundleIdentifier,
            appName: app?.localizedName,
            textBeforeCursor: reading.before,
            textAfterCursor: reading.after,
            caretRect: reading.caretRect,
            selectedRange: CFRange(location: reading.offset, length: 0),
            caretFont: reading.font,
            caretTextColor: reading.color,
            usesTextMarkers: true
        )
    }

    // MARK: - Text

    private func readText(_ element: AXUIElement, caret: Int) -> (before: String, after: String)? {
        let total = AX.int(element, kAXNumberOfCharactersAttribute as String)

        // Large documents: read only a window around the caret.
        if let total, total > windowedReadThreshold {
            let beforeStart = max(0, caret - maxContextBefore)
            let before = string(element, from: beforeStart, length: caret - beforeStart) ?? ""
            let after = string(element, from: caret, length: min(maxContextAfter, max(0, total - caret))) ?? ""
            return (before, after)
        }

        if let value = AX.string(element, kAXValueAttribute as String) {
            let text = value as NSString
            let caret = max(0, min(caret, text.length))
            let before = text.substring(to: caret)
            let after = text.substring(from: caret)
            return (String(before.suffix(maxContextBefore)), String(after.prefix(maxContextAfter)))
        }

        // Controls that expose no AXValue can still serve ranges.
        if let total {
            let beforeStart = max(0, caret - maxContextBefore)
            let before = string(element, from: beforeStart, length: caret - beforeStart) ?? ""
            let after = string(element, from: caret, length: min(maxContextAfter, max(0, total - caret))) ?? ""
            return (before, after)
        }

        return nil
    }

    private func string(_ element: AXUIElement, from location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        guard let parameter = AX.axValue(for: CFRange(location: location, length: length)) else {
            return nil
        }
        guard let value = AX.copyParameterized(
            element, kAXStringForRangeParameterizedAttribute as String, parameter
        ) else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    // MARK: - Geometry

    /// Resolves caret bounds.
    ///
    /// The trailing edge of the character *before* the caret is preferred over a
    /// zero-length range at the caret. Zero-length ranges are inconsistently
    /// implemented: TextEdit reports the caret a full line height above the
    /// glyphs (y=90 while the preceding character sits at y=103), which puts
    /// inline ghost text one line too high. A 1-length range is well defined
    /// everywhere, and the two agree horizontally.
    ///
    /// Straight after a newline there is no usable preceding character on this
    /// line, so the zero-length range is all we have.
    private func caretRect(
        _ element: AXUIElement,
        caret: Int,
        precededByNewline: Bool
    ) -> CGRect? {
        if caret > 0, !precededByNewline,
           let previous = boundsForRange(element, location: caret - 1, length: 1),
           isUsable(previous) {
            let collapsed = CGRect(
                x: previous.maxX,
                y: previous.origin.y,
                width: 0,
                height: previous.height
            )
            return AX.quartzToCocoa(collapsed)
        }

        if let rect = boundsForRange(element, location: caret, length: 0), isUsable(rect) {
            return AX.quartzToCocoa(rect)
        }

        // Bottom-left of the control itself.
        if let origin = AX.copy(element, kAXPositionAttribute as String),
           CFGetTypeID(origin) == AXValueGetTypeID(),
           let size = AX.copy(element, kAXSizeAttribute as String),
           CFGetTypeID(size) == AXValueGetTypeID() {
            var point = CGPoint.zero
            var extent = CGSize.zero
            if AXValueGetValue((origin as! AXValue), .cgPoint, &point),
               AXValueGetValue((size as! AXValue), .cgSize, &extent) {
                let rect = CGRect(x: point.x, y: point.y, width: 0, height: extent.height)
                if isUsable(rect) { return AX.quartzToCocoa(rect) }
            }
        }

        return nil
    }

    /// Screen rect (AppKit coordinates) of the text immediately before the caret
    /// that a correction replaces. Used to strike the typo where it actually
    /// sits.
    ///
    /// Takes the text rather than a length because the two paths below do not
    /// measure alike: an Accessibility range is UTF-16, while a text-marker walk
    /// steps one character at a time. Passing one number to both struck through
    /// the wrong span on any word holding a decomposed character.
    ///
    /// Dispatches on how the context was read: a marker-based element does not
    /// answer `AXBoundsForRange`, and its `selectedRange` is a derived count
    /// that would address the wrong text if passed back.
    func rect(replacing text: String, in context: FocusedTextContext) -> CGRect? {
        guard !text.isEmpty else { return nil }
        if context.usesTextMarkers {
            return TextMarkers.rect(charactersBeforeCaret: text.count, in: context.element)
        }
        let length = (text as NSString).length
        let start = context.selectedRange.location - length
        guard start >= 0 else { return nil }
        guard let quartz = boundsForRange(context.element, location: start, length: length),
              isUsable(quartz) else { return nil }
        return AX.quartzToCocoa(quartz)
    }

    /// Screen rect of the focused control itself, in AppKit coordinates.
    func fieldRect(of element: AXUIElement) -> CGRect? {
        guard let origin = AX.copy(element, kAXPositionAttribute as String),
              CFGetTypeID(origin) == AXValueGetTypeID(),
              let size = AX.copy(element, kAXSizeAttribute as String),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue((origin as! AXValue), .cgPoint, &point),
              AXValueGetValue((size as! AXValue), .cgSize, &extent),
              extent.width >= 8, extent.height >= 4 else { return nil }
        return AX.quartzToCocoa(CGRect(origin: point, size: extent))
    }

    /// Whether the caret is still inside the region its field actually draws in.
    ///
    /// Scrolling is invisible to everything else here: the text has not changed,
    /// the caret index has not changed, and `AXBoundsForRange` goes on answering
    /// for a line that has left the viewport — a well formed rect, somewhere the
    /// user can no longer see. Ghost text drawn against it ends up over a
    /// toolbar, or over whatever the scroll brought into its place.
    ///
    /// Answers true whenever the app will not say otherwise. A suggestion drawn
    /// slightly out of place is a smaller failure than one that never appears.
    func caretIsVisible(in context: FocusedTextContext) -> Bool {
        guard let caret = context.caretRect else { return true }

        // Exact wherever it is implemented, and AppKit text views implement it:
        // measured in TextEdit, the range tracks the scroll while the caret rect
        // goes on reporting a line that has left the window.
        //
        // Not consulted for marker-based elements, whose `selectedRange` is a
        // count derived by walking text markers rather than an index into the
        // space this attribute is expressed in. Nor where the answer is not a
        // range at all: Safari returns `location: Int.max, length: 0`, which is
        // meaningless, and one addition away from trapping on overflow.
        if !context.usesTextMarkers,
           let visible = AX.range(context.element, kAXVisibleCharacterRangeAttribute as String),
           visible.location >= 0, visible.length > 0,
           visible.location < Int.max - visible.length {
            let caretIndex = context.selectedRange.location
            if caretIndex < visible.location || caretIndex > visible.location + visible.length {
                return false
            }
        }

        guard let viewport = viewport(of: context.element) else { return true }
        // A zero-width caret intersects nothing, so the test has to be on a
        // point. The caret's middle rather than its edges: a line scrolled
        // halfway out counts as gone instead of being drawn over the boundary.
        // The horizontal slack is for a caret sitting exactly on the field's
        // trailing edge, which `contains` would otherwise call outside.
        return viewport.insetBy(dx: -6, dy: 0).contains(CGPoint(x: caret.minX, y: caret.midY))
    }

    /// The region a field's text is really drawn in: the field's own bounds,
    /// bounded outside by its window and inside by the nearest enclosing scroll
    /// area. Whichever of the three the app will answer for.
    ///
    /// No one of them is enough alone. A text view inside a scroll view reports
    /// its *document* rect — in TextEdit that is the whole document, several
    /// screens of it — so the field rect would call a caret scrolled up under
    /// the toolbar perfectly visible; the scroll area is what says otherwise. In
    /// a browser it is the other way round: the textarea's own rect is the clip
    /// for text scrolled inside it, while a page scrolled far enough carries the
    /// whole textarea out of the window, and only the window rect notices.
    private func viewport(of element: AXUIElement) -> CGRect? {
        var clip = fieldRect(of: element)
        // A direct attribute rather than a walk: every element knows its window.
        if let window = AX.element(element, kAXWindowAttribute as String),
           let rect = fieldRect(of: window) {
            clip = clip?.intersection(rect) ?? rect
        }
        var node = element
        // Deep enough to climb out of a web page's wrappers, shallow enough that
        // a miss costs a handful of round trips rather than a walk to the root.
        for _ in 0..<8 {
            guard let parent = AX.element(node, kAXParentAttribute as String) else { break }
            let role = AX.string(parent, kAXRoleAttribute as String)
            if role == kAXScrollAreaRole, let scroll = fieldRect(of: parent) {
                clip = clip?.intersection(scroll) ?? scroll
                break
            }
            // Past the window there is nothing left that can clip anything.
            if role == kAXWindowRole { break }
            node = parent
        }
        return clip
    }

    // MARK: - Typography

    /// Samples the character immediately before the caret: that is the run the
    /// suggestion will visually continue, so matching it makes the ghost text
    /// look like it belongs to the document.
    ///
    /// Accessibility does not vend an `NSFont`. It vends `AXFont`, a dictionary
    /// of name/family/size, and `AXForegroundColor` as a `CGColor`. Reading the
    /// AppKit keys instead silently yields nil in every app.
    private func typography(_ element: AXUIElement, caret: Int) -> (font: NSFont?, color: NSColor?) {
        guard caret > 0 else { return (nil, nil) }
        guard let parameter = AX.axValue(for: CFRange(location: caret - 1, length: 1)),
              let value = AX.copyParameterized(
                element, kAXAttributedStringForRangeParameterizedAttribute as String, parameter
              ),
              let attributed = value as? NSAttributedString,
              attributed.length > 0
        else { return (nil, nil) }

        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        return (AX.font(from: attributes), AX.color(from: attributes))
    }

    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        guard location >= 0,
              let parameter = AX.axValue(for: CFRange(location: location, length: length)) else {
            return nil
        }
        return AX.rect(from: AX.copyParameterized(
            element, kAXBoundsForRangeParameterizedAttribute as String, parameter
        ))
    }

    /// A caret legitimately has zero width, but zero height or a null origin
    /// means the app did not actually answer.
    private func isUsable(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite else { return false }
        guard rect.height > 0.5 else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        return !(rect.origin.x == 0 && rect.origin.y == 0)
    }

    // MARK: - Identity

    private func runningApp(of element: AXUIElement) -> NSRunningApplication? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
