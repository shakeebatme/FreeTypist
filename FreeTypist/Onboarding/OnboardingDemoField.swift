import AppKit
import SwiftUI

/// A self-contained rehearsal of the real interaction.
///
/// Scripted rather than driven by the engine: at this point in onboarding no
/// model has been downloaded and Accessibility has not been granted, so the real
/// pipeline cannot run. The point is to teach the gesture.
struct OnboardingDemoField: NSViewRepresentable {
    @Binding var accepted: Bool

    func makeNSView(context: Context) -> DemoView {
        let view = DemoView()
        view.onAccept = { accepted = true }
        return view
    }

    func updateNSView(_ view: DemoView, context: Context) {}

    final class DemoView: NSView {
        private let typed = "Thanks for taking the"
        private let remaining = [" time", " to", " read", " this."]
        private var takenWords = 0
        var onAccept: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == UInt16(Shortcut.tab) else { return super.keyDown(with: event) }
            guard takenWords < remaining.count else { return }
            takenWords += 1
            if takenWords >= 2 { onAccept?() }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            NSColor.textBackgroundColor.setFill()
            background.fill()
            NSColor.separatorColor.setStroke()
            background.stroke()

            let font = NSFont.systemFont(ofSize: 15)
            let solid = typed + remaining.prefix(takenWords).joined()
            let ghost = remaining.dropFirst(takenWords).joined()

            let solidText = NSAttributedString(
                string: solid,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            let origin = NSPoint(x: 12, y: (bounds.height - solidText.size().height) / 2)
            solidText.draw(at: origin)

            guard !ghost.isEmpty else { return }
            let ghostText = NSAttributedString(
                string: ghost,
                attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
            )
            ghostText.draw(at: NSPoint(x: origin.x + solidText.size().width, y: origin.y))

            // Caret between the two, as it would be in a real field.
            NSColor.controlAccentColor.setFill()
            NSRect(x: origin.x + solidText.size().width, y: origin.y + 2,
                   width: 1.5, height: solidText.size().height - 4).fill()
        }
    }
}
