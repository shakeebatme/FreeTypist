import AppKit
import ApplicationServices

/// Supplies the extra context a screenshot can give: text Accessibility could
/// not reach, and the colour behind the caret.
///
/// Capturing on every keystroke would be both slow and rude — ScreenCaptureKit
/// lights the purple recording indicator — so both results are cached and the
/// expensive path only runs when it can actually help.
@MainActor
final class ScreenContextProvider {
    struct Context {
        var ocrText: String?
        var backdrop: BackdropSampler.Backdrop?
    }

    private let capture = ScreenCaptureService()
    private let ocr = OCRService()

    private var cachedBackdrop: BackdropSampler.Backdrop?
    private var backdropKey: String = ""
    private var backdropAt: Date?

    private var cachedOCR: String?
    private var ocrKey: String = ""
    private var ocrAt: Date?
    /// The running screen scan, if any. Held so a second one is not started on
    /// top of it — a scan takes the better part of a second and there is a
    /// keystroke pause every few hundred milliseconds.
    private var scanTask: Task<Void, Never>?

    /// Backgrounds change when you switch app or scroll, not when you type.
    private let backdropTTL: TimeInterval = 4
    /// Surrounding text changes more often, but not per keystroke.
    private let ocrTTL: TimeInterval = 10
    /// The point past which a reading is not served at all, even for the app it
    /// was taken in. Comfortably longer than `ocrTTL`, so the previous scan
    /// keeps answering while the next one runs rather than leaving a hole.
    private let ocrHardTTL: TimeInterval = 40

    var isPermitted: Bool { ScreenCaptureService.hasPermission }

    func cached(for focus: FocusedTextContext) -> Context {
        Context(ocrText: servableOCR(key: ocrCacheKey(for: focus)),
                backdrop: servableBackdrop(key: backdropCacheKey(for: focus)))
    }

    /// Refreshes whatever is enabled and stale. Returns the current context.
    ///
    /// The backdrop is awaited — the ghost text cannot be drawn in the right
    /// colour without it — but the screen scan is not. See `startScreenScan`.
    @discardableResult
    func refresh(
        for focus: FocusedTextContext,
        wantsOCR: Bool,
        wantsBackdrop: Bool
    ) async -> Context {
        guard ScreenCaptureService.hasPermission else {
            return Context(ocrText: nil, backdrop: nil)
        }

        let backdropNow = backdropCacheKey(for: focus)
        let ocrNow = ocrCacheKey(for: focus)

        if wantsOCR, scanTask == nil, isStale(ocrAt, ocrTTL) || ocrNow != ocrKey {
            startScreenScan(for: focus, key: ocrNow)
        }
        if wantsBackdrop, isStale(backdropAt, backdropTTL) || backdropNow != backdropKey {
            await refreshBackdrop(for: focus, key: backdropNow)
        }

        return Context(
            ocrText: wantsOCR ? servableOCR(key: ocrNow) : nil,
            backdrop: wantsBackdrop ? servableBackdrop(key: backdropNow) : nil
        )
    }

    private func isStale(_ stamp: Date?, _ ttl: TimeInterval) -> Bool {
        guard let stamp else { return true }
        return Date().timeIntervalSince(stamp) > ttl
    }

    // MARK: - Cache keys

    private func backdropCacheKey(for focus: FocusedTextContext) -> String {
        "\(focus.bundleIdentifier ?? "?")|\(Int(focus.caretRect?.minY ?? 0))"
    }

    /// The scan covers the whole screen, so the caret's position within a window
    /// no longer changes what was read — only which app's text is subtracted
    /// from it as already-known. Quantising the caret, as this used to, bought
    /// nothing once the capture stopped being a band around it, and re-scanning
    /// every 120 points of scrolling cost a full second of Vision each time.
    private func ocrCacheKey(for focus: FocusedTextContext) -> String {
        focus.bundleIdentifier ?? "?"
    }

    // MARK: - Serving
    //
    // A reading is only context for the field it was taken around. The previous
    // version returned `cachedOCR` and `cachedBackdrop` unconditionally — the
    // TTL and key gated refreshing but never serving — so a value once cached
    // was handed out for the life of the process, following the caret from one
    // app into the next.

    private func servableOCR(key: String) -> String? {
        guard key == ocrKey, !isStale(ocrAt, ocrHardTTL) else { return nil }
        return cachedOCR
    }

    private func servableBackdrop(key: String) -> BackdropSampler.Backdrop? {
        guard key == backdropKey, !isStale(backdropAt, backdropTTL) else { return nil }
        return cachedBackdrop
    }

    // MARK: - Backdrop

    private func refreshBackdrop(for focus: FocusedTextContext, key: String) async {
        guard let caret = focus.caretRect else { return }
        // A sliver just right of the caret: that is exactly where the ghost text
        // will sit, so it is the only region whose colour matters.
        let strip = CGRect(
            x: caret.minX,
            y: caret.minY,
            width: 120,
            height: max(8, caret.height)
        )
        guard let frame = await capture.capture(rect: AX.cocoaToQuartz(strip)) else {
            Log.core.debug("backdrop capture returned nothing")
            return
        }
        if let backdrop = BackdropSampler.sample(frame) {
            Log.core.notice("backdrop luma=\(String(format: "%.2f", backdrop.luminance), privacy: .public) dark=\(backdrop.isDark, privacy: .public)")
            cachedBackdrop = backdrop
            backdropKey = key
            backdropAt = Date()
        }
    }

    // MARK: - Screen scan

    /// Reads every display and keeps the useful part.
    ///
    /// Two things changed here, and they depend on each other.
    ///
    /// *What is captured.* This used to photograph a 900×420 band of the
    /// focused window, on the theory that the context worth having is the
    /// thread above the reply box. That is one case. The other, and the one
    /// people actually notice, is a reference open beside what they are typing
    /// in — notes, a spec, the email being answered in a separate window. A
    /// capture clipped to the focused window cannot see any of it, so the
    /// feature looked switched off exactly when it was most needed. It also had
    /// to pass `hasSurroundingContent`, which demanded 160 points of the focused
    /// window not covered by the focused field, and so refused outright in a
    /// full-window editor — where everything on screen is in some other window
    /// by definition.
    ///
    /// *When it runs.* A display is roughly twenty times the pixels of that
    /// band, and awaiting it would put most of a second between the last
    /// keystroke and the ghost text. So the scan is fired and forgotten: the
    /// request in flight is served from the previous scan's cache, and this
    /// one lands for the next pause in typing. That is why `ocrHardTTL` is
    /// generous — the cache is not a fallback here, it is the normal path.
    private func startScreenScan(for focus: FocusedTextContext, key: String) {
        // Read on the main actor, before the hop: these are Accessibility calls
        // into the focused app, and the element may be gone by the time the
        // capture returns.
        let field = fieldRect(focus.element)
        let known = ScreenText.fold(focus.textBeforeCursor + " " + focus.textAfterCursor)
        let caret = focus.caretRect.map(AX.cocoaToQuartz)

        scanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.scanTask = nil }

            let frames = await self.capture.captureScreens(near: caret)
            guard !frames.isEmpty else {
                Log.core.debug("screen scan captured nothing")
                return
            }

            let outcome = await self.ocr.recognize(
                frames,
                budgetMilliseconds: OCRService.screenBudgetMilliseconds
            )
            Log.core.debug("screen scan \(frames.count, privacy: .public) displays \(outcome.milliseconds, privacy: .public)ms lines=\(outcome.lines.count, privacy: .public) skipped=\(outcome.skipped, privacy: .public) timedOut=\(outcome.timedOut, privacy: .public)")
            // Only a scan that never ran leaves the stamp alone, so the next
            // pause retries it immediately. A scan that ran and found nothing is
            // an answer — "there is nothing on screen worth carrying" — and it
            // has to be cached like any other, or a blank desktop would start a
            // fresh second of Vision at every pause in typing.
            guard !outcome.skipped else { return }

            // Anything inside the focused field already reached the prompt over
            // Accessibility; repeating it here would spend the budget saying the
            // same thing twice, and the half-typed word at the caret is the last
            // thing worth feeding back in.
            let text = ScreenText.condense(outcome.lines, excluding: field, known: known)
            Log.core.notice("screen text \(text.count, privacy: .public) chars")
            self.cachedOCR = text.isEmpty ? nil : text
            self.ocrKey = key
            self.ocrAt = Date()
        }
    }

    /// The focused element's own bounds, in Quartz coordinates — the space
    /// recognised text is reported in, so no conversion is needed to compare
    /// them.
    private func fieldRect(_ element: AXUIElement) -> CGRect? {
        guard let origin = AX.copy(element, kAXPositionAttribute as String),
              CFGetTypeID(origin) == AXValueGetTypeID(),
              let size = AX.copy(element, kAXSizeAttribute as String),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }

        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue((origin as! AXValue), .cgPoint, &point),
              AXValueGetValue((size as! AXValue), .cgSize, &extent) else { return nil }
        guard extent.width >= 8, extent.height >= 4 else { return nil }

        return CGRect(origin: point, size: extent)
    }
}
