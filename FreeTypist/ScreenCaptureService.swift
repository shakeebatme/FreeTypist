import AppKit
@preconcurrency import ScreenCaptureKit

/// A `CGImage` is immutable and safe to read from any thread, but is not marked
/// `Sendable`. This lets a captured frame cross to the OCR actor.
struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
    /// The screen rect the image covers, in Quartz coordinates.
    let rect: CGRect
}

/// One-shot screen captures, for OCR context and backdrop colour.
///
/// No capture ever contains a window of ours: either this app is excluded from
/// the frame, or it has nothing on screen to exclude, or the capture is refused.
/// Without that, the ghost text we just drew would be photographed and fed back
/// in as "context", and the suggestion would chase its own tail.
@MainActor
final class ScreenCaptureService {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// What a capture is for. The two callers run on different clocks — the
    /// backdrop sample sits between a keystroke and the ghost text, the screen
    /// scan runs in the background for a second at a time — so they get
    /// separate in-flight slots. Sharing one, which is what a single `inFlight`
    /// flag did, meant every scan silently swallowed the colour sample that
    /// keeps the suggestion legible.
    private enum Kind: Hashable { case region, screen }

    /// The longest edge an OCR frame is rendered at.
    ///
    /// A whole display at the Retina 2x the caret strip uses would be ~3000px
    /// wide and cost more time in Vision than the scan's whole budget. Below
    /// roughly 1.3x, body text stops resolving reliably at `.fast`. 2400 keeps
    /// a 13pt line around 20px on every Mac display size.
    private static let ocrMaxDimension: CGFloat = 2400

    private var cachedDisplays: [SCDisplay] = []
    private var cachedSelf: SCRunningApplication?
    private var contentFetchedAt: Date?
    private var inFlight: Set<Kind> = []

    /// Captures `rect` (Quartz coordinates). Returns nil when permission is
    /// missing, a capture is already running, or the rect is unusable.
    func capture(rect: CGRect) async -> CapturedFrame? {
        guard Self.hasPermission, !inFlight.contains(.region) else { return nil }
        guard rect.width >= 8, rect.height >= 4,
              rect.width.isFinite, rect.height.isFinite else { return nil }

        inFlight.insert(.region)
        defer { inFlight.remove(.region) }

        guard let display = await displays(covering: rect).first else { return nil }
        return await capture(rect: rect, on: display, scale: 2)
    }

    /// Captures every active display, the one holding `rect` first.
    ///
    /// This is the whole point of the screen scan: the text that decides a
    /// suggestion is routinely in a window the user is *not* typing in — a spec
    /// open beside the editor, a ticket beside the reply box — and a capture
    /// bounded by the focused window can never see it.
    ///
    /// Each display is captured at its `visibleFrame`, which is the frame less
    /// the menu bar and the Dock. Those two strips are pure chrome, they are
    /// the same on every scan, and the menu bar sits at the top left where
    /// reading order would have it outrank the actual content.
    func captureScreens(near rect: CGRect?) async -> [CapturedFrame] {
        guard Self.hasPermission, !inFlight.contains(.screen) else { return [] }

        inFlight.insert(.screen)
        defer { inFlight.remove(.screen) }

        var frames: [CapturedFrame] = []
        for display in await displays(covering: rect) {
            guard let area = visibleRect(of: display) else { continue }
            let scale = min(2, max(1, Self.ocrMaxDimension / max(area.width, area.height)))
            if let frame = await capture(rect: area, on: display, scale: scale) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// The readable part of a display — no menu bar, no Dock — in Quartz
    /// coordinates. Falls back to the whole display when AppKit has no matching
    /// screen, which happens briefly while displays are being reconfigured.
    private func visibleRect(of display: SCDisplay) -> CGRect? {
        let full = CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == display.displayID
        }
        guard let screen else { return full }
        let visible = AX.cocoaToQuartz(screen.visibleFrame)
        return visible.isNull || visible.width < 8 || visible.height < 4 ? full : visible
    }

    /// Shared body of both captures: build the self-excluding filter, clamp the
    /// rect to the display, and render.
    private func capture(rect: CGRect, on display: SCDisplay, scale: CGFloat) async -> CapturedFrame? {
        let filter: SCContentFilter
        if let cachedSelf {
            filter = SCContentFilter(display: display, excludingApplications: [cachedSelf], exceptingWindows: [])
        } else if !hasVisibleWindow {
            // Nothing of ours is on screen, so there is nothing to exclude.
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            // A window of ours is up but we could not find ourselves in the
            // shareable content, so it cannot be excluded. Refuse the capture:
            // losing one OCR pass costs a little context, photographing our own
            // ghost text corrupts it.
            return nil
        }

        // Display-relative source rect, clamped to the display.
        let displayRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let local = rect.offsetBy(dx: -CGFloat(display.frame.origin.x),
                                  dy: -CGFloat(display.frame.origin.y))
            .intersection(displayRect)
        guard !local.isNull, local.width >= 8, local.height >= 4 else { return nil }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = local
        configuration.width = Int(local.width * scale)
        configuration.height = Int(local.height * scale)
        configuration.scalesToFit = false
        configuration.showsCursor = false
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            // The frame covers `local`, not the rect that was asked for: the
            // clamp above may have trimmed it. OCR maps recognised boxes back
            // through this rect, so it has to be the one actually rendered.
            return CapturedFrame(
                image: image,
                rect: local.offsetBy(dx: CGFloat(display.frame.origin.x),
                                     dy: CGFloat(display.frame.origin.y))
            )
        } catch {
            return nil
        }
    }

    /// True while any window of ours is on screen and could be photographed.
    private var hasVisibleWindow: Bool {
        NSApp.windows.contains { $0.isVisible }
    }

    /// Shareable content is expensive to enumerate, so it is cached briefly.
    /// Returns every display, the one intersecting `rect` first.
    ///
    /// `cachedSelf` is the exception to that cache. The content list only names
    /// applications that currently own an on-screen window, and this app is an
    /// `LSUIElement` that usually owns none — measured: idle, it does not appear
    /// in the list at all. A nil result therefore means "ask again", never an
    /// answer worth keeping: caching it leaves the next five seconds of captures
    /// excluding nothing, and the overlay only has to appear inside that window
    /// to be photographed and fed back in as context.
    private func displays(covering rect: CGRect?) async -> [SCDisplay] {
        let stale = contentFetchedAt.map { Date().timeIntervalSince($0) > 5 } ?? true
        // Only worth re-asking when there is something of ours to exclude.
        let needsSelf = cachedSelf == nil && hasVisibleWindow
        if stale || cachedDisplays.isEmpty || needsSelf {
            if let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            ) {
                let ownID = ProcessInfo.processInfo.processIdentifier
                cachedSelf = content.applications.first { $0.processID == ownID }
                cachedDisplays = content.displays
                contentFetchedAt = Date()
            }
        }

        guard let rect else { return cachedDisplays }
        // Caret's display first: it is the one whose text is most likely to
        // matter, and on a timeout it is the one that got scanned. Partitioned
        // rather than sorted because `sorted` is not documented as stable and
        // the order of the remaining displays should not shuffle between scans.
        let holding = cachedDisplays.filter { $0.frame.intersects(rect) }
        let rest = cachedDisplays.filter { !$0.frame.intersects(rect) }
        return holding + rest
    }
}
