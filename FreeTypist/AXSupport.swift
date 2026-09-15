import AppKit
import ApplicationServices

/// Type-safe wrappers around the C Accessibility API.
///
/// Every accessor is failable rather than force-casting: a focused element in a
/// foreign app can return any CFType (or nothing), and a force cast there takes
/// the whole app down.
enum AX {
    /// The system default is 6 seconds. A busy target app would otherwise stall
    /// our main thread for that long on every read.
    static func configureMessagingTimeout(_ seconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func copyParameterized(
        _ element: AXUIElement,
        _ attribute: String,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, attribute as CFString, parameter, &value
        ) == .success else { return nil }
        return value
    }

    /// Handles both plain and attributed string values; web areas and rich text
    /// controls routinely return the latter.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    static func int(_ element: AXUIElement, _ attribute: String) -> Int? {
        (copy(element, attribute) as? NSNumber)?.intValue
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = copy(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    static func rect(from value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((value as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    static func axValue(for range: CFRange) -> CFTypeRef? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }


    // MARK: - Typography

    /// Accessibility does not vend an `NSFont`. It vends `AXFont`, a dictionary
    /// of name/family/size, and `AXForegroundColor` as a `CGColor`. Reading the
    /// AppKit keys instead silently yields nil in every app.
    ///
    /// Shared because the range API and the text-marker API return the same
    /// attribute dictionaries through different parameterized attributes.
    static func font(from attributes: [NSAttributedString.Key: Any]) -> NSFont? {
        // Literal keys, confirmed against a live app: the SDK constants are
        // Unmanaged<CFString> and reading them trips strict concurrency.
        guard let descriptor = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] else {
            return attributes[.font] as? NSFont
        }
        let size = (descriptor["AXFontSize"] as? NSNumber)?.doubleValue ?? 13
        let name = descriptor["AXFontName"] as? String
            ?? descriptor["AXFontFamily"] as? String
        if let name, let font = NSFont(name: name, size: size) { return font }
        return .systemFont(ofSize: size)
    }

    static func color(from attributes: [NSAttributedString.Key: Any]) -> NSColor? {
        guard let raw = attributes[NSAttributedString.Key("AXForegroundColor")] else {
            return attributes[.foregroundColor] as? NSColor
        }
        let value = raw as CFTypeRef
        guard CFGetTypeID(value) == CGColor.typeID else { return nil }
        return NSColor(cgColor: (value as! CGColor))
    }

    // MARK: - Coordinates

    /// Accessibility reports geometry in Quartz screen space: origin at the
    /// top-left of the primary display, +y pointing down. AppKit windows use
    /// origin bottom-left, +y pointing up. Positioning a window with an
    /// unconverted AX rect puts it roughly one screen-height away from the
    /// caret, which is why an overlay can appear to never show up at all.
    static func quartzToCocoa(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: primary.frame.maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The inverse: ScreenCaptureKit wants Quartz coordinates, so a rect
    /// converted for AppKit has to be converted back before it can be captured.
    ///
    /// The body is identical to `quartzToCocoa` on purpose — `y' = H - y - h` is
    /// its own inverse. Kept as two named functions because call sites read far
    /// better for it, and flipping the wrong way is the bug that made the overlay
    /// land a screen-height away from the caret.
    static func cocoaToQuartz(_ rect: CGRect) -> CGRect {
        quartzToCocoa(rect)
    }
}
