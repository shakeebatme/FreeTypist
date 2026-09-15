import AppKit
import CoreGraphics

/// Identifies keyboard events this app posted, so its own event tap can tell
/// them apart from the user's typing.
///
/// `.eventSourceUserData` is a free 64-bit field that rides along with a posted
/// event and is not otherwise used, so an arbitrary constant is enough.
enum SyntheticEvent {
    static let marker: Int64 = 0x46_54_79_70_69_73_74   // "FTypist"

    /// Stamps an event as ours and strips the modifiers it was born holding.
    ///
    /// `CGEventSource(stateID: .combinedSessionState)` seeds a new event from the
    /// *live* keyboard, so whatever the user is physically holding rides along
    /// with text we post, and nothing clears it afterwards. That is not a corner
    /// case here: the accept shortcuts are rebindable with all four modifiers and
    /// two ship carrying them — `forceActivate` is ⌃` and `toggleCurrentApp` is
    /// ⌃⌥⌘` — so a key still down when the insertion fires is ordinary. A run of
    /// characters flagged with Command is a run of menu shortcuts, and the
    /// backspaces ahead of it are worse.
    static func stamp(_ event: CGEvent) {
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    /// Whether this event is one we posted.
    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}

enum KeyDisposition {
    /// Let the keystroke reach the focused app unchanged.
    case pass
    /// Swallow the keystroke. Required for Tab: otherwise accepting a
    /// suggestion also inserts a tab character or moves focus.
    case consume
}

struct KeyStroke: Sendable {
    let keyCode: Int64
    let flags: CGEventFlags

    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36

    /// Modifier chords are app shortcuts, not typing.
    var isCommandLike: Bool {
        flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
    }
}

/// A session-level CGEvent tap. Unlike `NSEvent.addGlobalMonitorForEvents`,
/// a tap can decide an event's fate, which is what makes Tab-to-accept possible.
@MainActor
final class KeyEventTap {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onKeyDown: ((KeyStroke) -> KeyDisposition)?

    private(set) var isRunning = false

    /// Returns false when Accessibility permission is missing; a tap created
    /// with `.defaultTap` requires it.
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: freeTypistKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isRunning = false
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        self.port = port
        self.runLoopSource = source
        isRunning = true
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        port = nil
        runLoopSource = nil
        isRunning = false
    }

    /// The system disables a tap that takes too long in its callback, or on
    /// certain user input. Re-arm instead of silently going deaf.
    fileprivate func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    fileprivate func handle(_ stroke: KeyStroke) -> KeyDisposition {
        onKeyDown?(stroke) ?? .pass
    }
}

/// Must live at file scope: a C function pointer cannot capture context.
/// The tap's run loop source is installed on the main run loop, so this always
/// runs on the main thread and `assumeIsolated` is sound.
private func freeTypistKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { tap.reenable() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else { return Unmanaged.passUnretained(event) }

    // Events we posted ourselves must not be mistaken for the user typing.
    // `TextInsertionService` falls back to synthesized keystrokes whenever an
    // app will not take an Accessibility write, and those are posted to the
    // same session tap this callback listens on. Treating them as typing wipes
    // the suggestion that was just re-anchored, so word-by-word Tab worked once
    // and then let the next Tab through to the app — which in a browser moves
    // focus to the next field.
    if SyntheticEvent.isOurs(event) {
        return Unmanaged.passUnretained(event)
    }

    // Only Sendable values cross into the actor-isolated closure; the CGEvent
    // itself stays here.
    let stroke = KeyStroke(
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags
    )
    let disposition = MainActor.assumeIsolated { tap.handle(stroke) }
    return disposition == .consume ? nil : Unmanaged.passUnretained(event)
}
