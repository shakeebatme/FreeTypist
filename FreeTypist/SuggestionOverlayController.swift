import AppKit

/// Draws the suggestion as grey ghost text sitting inline with the caret, in
/// the target app's own font.
///
/// Nothing can draw into another process's text view, so this is a transparent,
/// click-through window positioned exactly at the caret. Because suggestions are
/// only offered at the end of a line, the ghost text never covers real text.
@MainActor
final class SuggestionOverlayController {
    private let inlinePanel: NSPanel
    private let ghost: GhostTextView

    /// Corrections replace a word that is already on screen, so ghost text at the
    /// caret would misrepresent them. Those fall back to a labelled pill, as does
    /// any app that will not report caret geometry.
    private let pillPanel: NSPanel
    private let pillBackground: NSVisualEffectView
    private let pillLabel: NSTextField
    private let pillBadge: NSTextField

    private(set) var isVisible = false

    init() {
        ghost = GhostTextView()
        inlinePanel = Self.makePanel()
        inlinePanel.contentView = ghost

        pillLabel = NSTextField(labelWithString: "")
        pillLabel.font = .systemFont(ofSize: 13)
        pillLabel.lineBreakMode = .byTruncatingTail
        pillLabel.maximumNumberOfLines = 1
        pillLabel.translatesAutoresizingMaskIntoConstraints = false

        pillBadge = NSTextField(labelWithString: "tab")
        pillBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        pillBadge.textColor = .secondaryLabelColor
        pillBadge.alignment = .center
        pillBadge.wantsLayer = true
        pillBadge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        pillBadge.layer?.cornerRadius = 3
        pillBadge.translatesAutoresizingMaskIntoConstraints = false

        pillBackground = NSVisualEffectView()
        pillBackground.material = .hudWindow
        pillBackground.blendingMode = .behindWindow
        pillBackground.state = .active
        pillBackground.wantsLayer = true
        pillBackground.layer?.cornerRadius = 7

        pillPanel = Self.makePanel()
        pillPanel.hasShadow = true
        pillPanel.contentView = pillBackground

        pillBackground.addSubview(pillLabel)
        pillBackground.addSubview(pillBadge)
        NSLayoutConstraint.activate([
            pillLabel.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 9),
            pillLabel.centerYAnchor.constraint(equalTo: pillBackground.centerYAnchor),
            pillBadge.leadingAnchor.constraint(equalTo: pillLabel.trailingAnchor, constant: 8),
            pillBadge.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -7),
            pillBadge.centerYAnchor.constraint(equalTo: pillBackground.centerYAnchor),
            pillBadge.widthAnchor.constraint(equalToConstant: 24),
            pillBadge.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 20),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // `.stationary` is the flag that pins a window in place through Mission
        // Control and Exposé — "unaffected by Exposé", in Apple's words, which
        // is exactly wrong for text that only means anything while it sits on
        // the caret it belongs to. `.transient` is the documented opposite: the
        // panel is taken off screen while Exposé is up and comes back with the
        // desktop. Space membership is left at the default for the same reason;
        // `.canJoinAllSpaces` carried the ghost text onto every other space.
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    func show(
        _ suggestion: Suggestion,
        at caretRect: CGRect?,
        font: NSFont?,
        textColor: NSColor?,
        ghostColor: NSColor? = nil,
        strikeRect: CGRect? = nil
    ) {
        guard !suggestion.isEmpty else {
            hide()
            return
        }

        if suggestion.isCorrection, let caretRect, let strikeRect {
            // A correction rewrites a word already on screen, so show it there:
            // strike the typo where it sits and put the fix beside it.
            showCorrection(suggestion, typo: strikeRect, caret: caretRect, font: font, ghostColor: ghostColor)
        } else if let caretRect, !suggestion.isCorrection {
            showInline(suggestion, at: caretRect, font: font, textColor: textColor, ghostColor: ghostColor)
        } else {
            showPill(suggestion, at: caretRect)
        }
        isVisible = true
    }

    // MARK: - Correction

    /// Draws a line through the misspelled word and the fix immediately after
    /// the caret, matching "show it inline as a strikethrough on the typo with
    /// the fix next to it".
    private func showCorrection(
        _ suggestion: Suggestion,
        typo: CGRect,
        caret: CGRect,
        font: NSFont?,
        ghostColor: NSColor?
    ) {
        pillPanel.orderOut(nil)

        let resolvedFont = font ?? .systemFont(ofSize: max(11, caret.height * 0.72))
        let accent = NSColor.systemBlue
        let attributed = NSAttributedString(
            string: " " + suggestion.text,
            attributes: [.font: resolvedFont, .foregroundColor: accent]
        )
        let textSize = attributed.size()

        // One window spanning the typo and the fix drawn after it.
        let left = min(typo.minX, caret.minX)
        let right = max(typo.maxX, caret.maxX) + ceil(textSize.width) + 4
        let bottom = min(typo.minY, caret.minY)
        let height = max(typo.height, max(caret.height, ceil(textSize.height)))
        let frame = NSRect(x: left, y: bottom, width: right - left, height: height)

        ghost.attributed = attributed
        ghost.textOrigin = NSPoint(x: max(typo.maxX, caret.maxX) - left, y: 0)
        ghost.strikeThrough = NSRect(
            x: typo.minX - left,
            y: typo.minY - bottom,
            width: typo.width,
            height: typo.height
        )
        ghost.strikeColor = accent

        inlinePanel.setFrame(frame, display: false)
        ghost.needsDisplay = true
        inlinePanel.displayIfNeeded()
        inlinePanel.orderFrontRegardless()
    }

    func hide() {
        guard isVisible else { return }
        inlinePanel.orderOut(nil)
        pillPanel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Inline ghost text

    private func showInline(
        _ suggestion: Suggestion,
        at caretRect: CGRect,
        font: NSFont?,
        textColor: NSColor?,
        ghostColor: NSColor?
    ) {
        pillPanel.orderOut(nil)

        // Fall back to a size derived from the line height when the app will not
        // report its font.
        let resolvedFont = font ?? .systemFont(ofSize: max(11, caretRect.height * 0.72))
        // A sampled backdrop colour is authoritative when available: tinting the
        // app's own text colour guesses wrong on a dark background, where 42%
        // black is invisible.
        let resolved = ghostColor ?? (textColor ?? .textColor).withAlphaComponent(0.42)

        let screen = screenContaining(caretRect.origin) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let available = max(40, visible.maxX - caretRect.minX - 6)

        let attributed = Self.fit(
            suggestion.text.replacingOccurrences(of: "\n", with: " "),
            font: resolvedFont,
            color: resolved,
            maxWidth: available
        )

        let size = attributed.size()
        let height = max(caretRect.height, ceil(size.height))
        let frame = NSRect(
            x: caretRect.minX,
            y: caretRect.minY,
            width: ceil(size.width) + 2,
            height: height
        )

        ghost.attributed = attributed
        ghost.textOrigin = .zero
        ghost.strikeThrough = nil
        inlinePanel.setFrame(frame, display: false)
        // Redraw the whole view, not just the region a resize exposed: AppKit
        // otherwise hands `draw` a partial dirty rect and the previous
        // suggestion's glyphs survive in the backing store, so two greys end up
        // superimposed.
        ghost.needsDisplay = true
        inlinePanel.displayIfNeeded()
        inlinePanel.orderFrontRegardless()
    }

    /// Truncates to the available width with an ellipsis. Drawing is done at a
    /// fixed origin to keep the baseline exact, so the string has to be shortened
    /// up front rather than clipped by the view.
    private static func fit(
        _ text: String,
        font: NSFont,
        color: NSColor,
        maxWidth: CGFloat
    ) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var candidate = text
        var attributed = NSAttributedString(string: candidate, attributes: attributes)
        while attributed.size().width > maxWidth, candidate.count > 1 {
            candidate = String(candidate.dropLast(max(1, candidate.count / 8)))
            attributed = NSAttributedString(string: candidate + "…", attributes: attributes)
        }
        return attributed
    }

    // MARK: - Pill

    private func showPill(_ suggestion: Suggestion, at caretRect: CGRect?) {
        inlinePanel.orderOut(nil)

        pillLabel.stringValue = suggestion.text.replacingOccurrences(of: "\n", with: " ")
        pillLabel.textColor = suggestion.isCorrection ? .systemBlue : .labelColor

        let width = min(max(90, pillLabel.attributedStringValue.size().width + 48), 420)
        let size = NSSize(width: width, height: 26)
        pillPanel.setContentSize(size)
        pillPanel.setFrameOrigin(pillOrigin(for: caretRect, size: size))
        pillPanel.orderFrontRegardless()
    }

    private func pillOrigin(for caretRect: CGRect?, size: NSSize) -> NSPoint {
        let screen = screenContaining(caretRect?.origin) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        guard let caretRect else {
            return NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24)
        }

        var x = caretRect.minX
        var y = caretRect.minY - size.height - 5
        if y < visible.minY + 4 { y = caretRect.maxY + 5 }
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: x, y: y)
    }

    private func screenContaining(_ point: CGPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// Draws the string with its box bottom at the view's bottom edge. The window is
/// positioned with its bottom on the caret rect's bottom, so the text baseline
/// lands on the document's baseline.
private final class GhostTextView: NSView {
    var attributed: NSAttributedString? {
        didSet { needsDisplay = true }
    }
    /// Where the text sits within the view; non-zero for corrections, which draw
    /// the fix after the struck-through word.
    var textOrigin: NSPoint = .zero
    /// Rect of the word being corrected, struck through in place.
    var strikeThrough: NSRect?
    var strikeColor: NSColor = .systemBlue

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // `.copy` genuinely zeroes the pixels; the default blend would leave the
        // previous frame showing through a transparent window.
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        if let strikeThrough {
            strikeColor.setStroke()
            let line = NSBezierPath()
            line.lineWidth = max(1, strikeThrough.height * 0.08)
            let y = strikeThrough.midY
            line.move(to: NSPoint(x: strikeThrough.minX, y: y))
            line.line(to: NSPoint(x: strikeThrough.maxX, y: y))
            line.stroke()
        }

        attributed?.draw(at: textOrigin)
    }
}
