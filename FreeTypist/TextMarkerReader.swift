import AppKit
import ApplicationServices

/// Reads WebKit editable areas, which implement a completely different text API
/// from AppKit's.
///
/// `FocusedTextReader` keys everything off `AXSelectedTextRange`: an integer
/// caret offset, plus `AXStringForRange` and `AXBoundsForRange` to read around
/// it. A WebKit `AXWebArea` — Mail's compose body, Notes, any `contenteditable`
/// — exposes **none** of those. It offers *text markers* instead: opaque tokens
/// standing for a position in the document, with parameterized attributes that
/// take marker *ranges* rather than character ranges.
///
/// Measured against Mail's compose window, the focused element reported
/// `hasSelectedTextRange=false` and an `AXValue` of 0 characters, so the reader
/// returned nil and the app looked dead. Through markers the identical element
/// yields the text before and after the caret, caret bounds, and `AXFont`.
///
/// Not every web area needs this: Safari's ordinary text inputs do vend
/// `AXSelectedTextRange`, which is why Safari worked while Mail did not. This is
/// tried only after the range path declines.
enum TextMarkers {

    /// Everything the range path produces, so the two are interchangeable.
    struct Reading {
        let before: String
        let after: String
        /// Caret bounds in AppKit screen coordinates.
        let caretRect: CGRect?
        let font: NSFont?
        let color: NSColor?
        /// Characters between the start of the document and the caret. Purely an
        /// identity/arithmetic aid — markers, not this, address the document.
        let offset: Int
    }

    /// Marker traversal costs one AX round trip per hop, so a very long document
    /// is read a paragraph at a time rather than from the top.
    private static let paragraphWalkLimit = 12

    static func isAvailable(_ element: AXUIElement) -> Bool {
        markerRange(element, "AXSelectedTextMarkerRange") != nil
    }

    static func read(
        _ element: AXUIElement,
        maxBefore: Int,
        maxAfter: Int
    ) -> Reading? {
        guard let selection = markerRange(element, "AXSelectedTextMarkerRange") else { return nil }

        // A non-empty selection means the user is selecting, not typing. The
        // range path checks `length == 0`; the marker equivalent is a length of
        // zero characters across the selection range.
        if let length = int(element, "AXLengthForTextMarkerRange", selection), length != 0 {
            return nil
        }

        let caret = AXTextMarkerRangeCopyStartMarker(selection)

        guard let documentStart = marker(element, "AXStartTextMarker") else { return nil }
        let beforeRange = boundedRangeBeforeCaret(
            element, documentStart: documentStart, caret: caret, limit: maxBefore
        )
        guard let before = string(element, beforeRange) else { return nil }

        var after = ""
        if let documentEnd = marker(element, "AXEndTextMarker") {
            let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, caret, documentEnd)
            after = string(element, range) ?? ""
        }

        // Same anchoring rule as the range path: the trailing edge of the
        // preceding character beats a zero-length caret rect, except straight
        // after a newline where there is no character on this line to anchor to.
        let precededByNewline = before.last?.isNewline ?? true
        let previous = precededByNewline ? nil : previousCharacterRange(element, caret: caret)

        var caretRect: CGRect?
        if let previous, let rect = bounds(element, previous), isUsable(rect) {
            caretRect = AX.quartzToCocoa(
                CGRect(x: rect.maxX, y: rect.origin.y, width: 0, height: rect.height)
            )
        } else if let rect = bounds(element, selection), isUsable(rect) {
            caretRect = AX.quartzToCocoa(rect)
        }

        var font: NSFont?
        var color: NSColor?
        if let previous, let attributes = attributes(element, previous) {
            font = AX.font(from: attributes)
            color = AX.color(from: attributes)
        }

        return Reading(
            before: String(before.suffix(maxBefore)),
            after: String(after.prefix(maxAfter)),
            caretRect: caretRect,
            font: font,
            color: color,
            offset: before.count
        )
    }

    /// Screen rect of the `count` characters immediately before the caret, so a
    /// correction can be struck through where it actually sits. The range path's
    /// `AXBoundsForRange` equivalent.
    static func rect(charactersBeforeCaret count: Int, in element: AXUIElement) -> CGRect? {
        guard count > 0, let selection = markerRange(element, "AXSelectedTextMarkerRange") else {
            return nil
        }
        var start = AXTextMarkerRangeCopyStartMarker(selection)
        let end = start
        for _ in 0..<count {
            guard let previous = marker(element, "AXPreviousTextMarkerForTextMarker", start) else {
                return nil
            }
            start = previous
        }
        let range = AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)
        guard let rect = bounds(element, range), isUsable(rect) else { return nil }
        return AX.quartzToCocoa(rect)
    }

    // MARK: - Traversal

    /// Reading from the top of the document is one AX call, but on a long page
    /// it hands back the whole thing on every keystroke. Past a threshold, walk
    /// back paragraph by paragraph until there is enough context.
    private static func boundedRangeBeforeCaret(
        _ element: AXUIElement,
        documentStart: AXTextMarker,
        caret: AXTextMarker,
        limit: Int
    ) -> AXTextMarkerRange {
        let whole = AXTextMarkerRangeCreate(kCFAllocatorDefault, documentStart, caret)
        guard let length = int(element, "AXLengthForTextMarkerRange", whole), length > limit * 3 else {
            return whole
        }

        var start = caret
        for _ in 0..<paragraphWalkLimit {
            guard let previous = marker(
                element, "AXPreviousParagraphStartTextMarkerForTextMarker", start
            ) else { break }
            let candidate = AXTextMarkerRangeCreate(kCFAllocatorDefault, previous, caret)
            guard let span = int(element, "AXLengthForTextMarkerRange", candidate) else { break }
            start = previous
            if span >= limit { break }
        }
        return AXTextMarkerRangeCreate(kCFAllocatorDefault, start, caret)
    }

    private static func previousCharacterRange(
        _ element: AXUIElement,
        caret: AXTextMarker
    ) -> AXTextMarkerRange? {
        guard let previous = marker(element, "AXPreviousTextMarkerForTextMarker", caret) else {
            return nil
        }
        return AXTextMarkerRangeCreate(kCFAllocatorDefault, previous, caret)
    }

    // MARK: - Typed accessors
    //
    // The marker types are CFTypes with no Swift bridging, so every value that
    // crosses the boundary is type-checked before it is cast. A force cast on a
    // foreign app's reply takes the whole app down.

    private static func marker(_ element: AXUIElement, _ attribute: String) -> AXTextMarker? {
        guard let value = AX.copy(element, attribute),
              CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    private static func marker(
        _ element: AXUIElement,
        _ attribute: String,
        _ parameter: CFTypeRef
    ) -> AXTextMarker? {
        guard let value = AX.copyParameterized(element, attribute, parameter),
              CFGetTypeID(value) == AXTextMarkerGetTypeID() else { return nil }
        return (value as! AXTextMarker)
    }

    private static func markerRange(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXTextMarkerRange? {
        guard let value = AX.copy(element, attribute),
              CFGetTypeID(value) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (value as! AXTextMarkerRange)
    }

    private static func string(_ element: AXUIElement, _ range: AXTextMarkerRange) -> String? {
        guard let value = AX.copyParameterized(element, "AXStringForTextMarkerRange", range) else {
            return nil
        }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func attributes(
        _ element: AXUIElement,
        _ range: AXTextMarkerRange
    ) -> [NSAttributedString.Key: Any]? {
        guard let value = AX.copyParameterized(
            element, "AXAttributedStringForTextMarkerRange", range
        ), let attributed = value as? NSAttributedString, attributed.length > 0 else { return nil }
        return attributed.attributes(at: 0, effectiveRange: nil)
    }

    private static func bounds(_ element: AXUIElement, _ range: AXTextMarkerRange) -> CGRect? {
        AX.rect(from: AX.copyParameterized(element, "AXBoundsForTextMarkerRange", range))
    }

    private static func int(
        _ element: AXUIElement,
        _ attribute: String,
        _ parameter: CFTypeRef
    ) -> Int? {
        (AX.copyParameterized(element, attribute, parameter) as? NSNumber)?.intValue
    }

    /// A caret legitimately has zero width, but zero height or a null origin
    /// means the app did not actually answer.
    private static func isUsable(_ rect: CGRect) -> Bool {
        guard !rect.isNull, !rect.isInfinite, rect.height > 0.5 else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        return !(rect.origin.x == 0 && rect.origin.y == 0)
    }
}
