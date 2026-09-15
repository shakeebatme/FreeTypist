import AppKit
import SwiftUI

/// Records a key combination, without pulling in MASShortcut.
///
/// Captures at the `NSView` level rather than through SwiftUI, because a bare
/// modifier press and keys like Tab and Escape never reach a SwiftUI key handler.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut?
        var onCapture: ((Shortcut?) -> Void)?
        private var recording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 116, height: 22) }

        override func mouseDown(with event: NSEvent) {
            recording.toggle()
            if recording { window?.makeFirstResponder(self) }
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }

            // Escape cancels recording rather than binding itself: its meaning
            // is configured separately, and binding it here would be a trap.
            if event.keyCode == UInt16(Shortcut.escape) {
                recording = false
                return
            }

            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            onCapture?(Shortcut(keyCode: Int64(event.keyCode), modifiers: flags))
            recording = false
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                       : NSColor.quaternaryLabelColor.withAlphaComponent(0.4)).setFill()
            rounded.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            rounded.stroke()

            let label = recording ? "Press keys…" : (shortcut?.display ?? "Record Shortcut")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: shortcut == nil ? .regular : .medium),
                .foregroundColor: recording ? NSColor.controlAccentColor
                                            : (shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor),
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2))
        }
    }
}
