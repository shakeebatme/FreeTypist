import AppKit

/// Apps whose accessibility support is too thin for inline completion, and the
/// reason for each.
///
/// Inline ghost text needs three things from the focused element: the text
/// before the caret, *where* the caret is on screen, and a way to write back.
/// Most apps provide all three through character ranges; WebKit rich text
/// provides them through `TextMarkers`. A few provide none of it, and there is
/// no third API to fall back on.
///
/// Saying so is the feature. Without it the app simply does nothing in these
/// apps and looks broken — which is exactly how this was reported.
enum AppCompatibility {

    struct Limitation: Equatable {
        /// One line for the menu bar header. Names the app, because that
        /// header is read without any other context around it.
        ///
        /// Must stay short: menu items clip rather than wrap, and the menu's
        /// width is set by the action items below it. The full explanation
        /// belongs in `detail`.
        let summary: String
        /// The specific missing piece. Also names the app, and is shown on its
        /// own in the settings Status row.
        let detail: String
    }

    /// Measured, not assumed. Each entry below was probed against the live app.
    private static let known: [String: Limitation] = [
        "com.mitchellh.ghostty": ghostty,
        "com.mitchellh.ghostty.debug": ghostty,
    ]

    /// Ghostty's focused element is an `AXTextArea` that answers `AXValue` with
    /// the visible screen, but:
    ///
    /// - `AXSelectedTextRange` is always `{0, 0}`, at a shell prompt and inside
    ///   a full-screen TUI alike, so the caret offset is unknowable; and
    /// - it implements no parameterized attributes at all, so
    ///   `AXBoundsForRange` returns nothing for every range, and the caret
    ///   cannot be located on screen.
    ///
    /// Assuming the caret sits at the end of the buffer would work at a bare
    /// shell prompt and be wrong in every full-screen program, so the completion
    /// would attach itself to whatever text happened to be last on screen.
    /// Refusing is the better answer.
    private static let ghostty = Limitation(
        summary: "Ghostty doesn't expose caret position.",
        detail: """
            Ghostty reports the caret at position 0 no matter where it is, and \
            answers no bounds queries, so there is nowhere to put the \
            suggestion. Terminal.app and iTerm2 work.
            """
    )

    static func limitation(for bundleID: String?) -> Limitation? {
        guard let bundleID else { return nil }
        return known[bundleID]
    }

    static func isKnownUnsupported(_ bundleID: String?) -> Bool {
        limitation(for: bundleID) != nil
    }
}
