import AppKit
import Carbon.HIToolbox

/// Global hot keys registered through Carbon's `RegisterEventHotKey`.
///
/// `KeyEventTap` is how FreeTypist normally sees a keystroke, and it is also the
/// one thing macOS switches off. While *secure event input* is on — a focused
/// password field, a terminal sitting at a password prompt, a password manager —
/// the window server stops delivering key events to session taps altogether. The
/// tap stays installed and enabled and simply never fires again. Accessibility
/// reads are untouched, so suggestions keep appearing while Tab sails past into
/// the app underneath, which is exactly the shape of the bug this fixes.
///
/// Carbon hot keys are dispatched ahead of that gate and keep firing. Measured
/// here: with secure input enabled, a session tap saw nothing of a keystroke
/// that a hot key bound to the same chord still received.
///
/// The two paths compose rather than race. A tap that *consumes* a key wins
/// outright — the hot key bound to it does not fire — so these only ever run in
/// the window where the tap could not, and nothing is ever accepted twice.
@MainActor
final class HotKeyMonitor {
    /// Fired when a registered hot key is pressed.
    ///
    /// By the time this runs the key is already swallowed: Carbon gives no way
    /// to hand one back. `sync` carries the whole decision about which keys are
    /// ours, which is why its predicate has to mirror `perform`'s guards.
    var onAction: ((ShortcutAction) -> Void)?

    /// Identifies our own hot keys in the shared application event target.
    fileprivate nonisolated static let signature: OSType = 0x46_54_79_70  // "FTyp"

    private struct Registration {
        let ref: EventHotKeyRef
        let shortcut: Shortcut
    }

    private var registered: [ShortcutAction: Registration] = [:]
    private var handler: EventHandlerRef?

    /// Brings the registered set in line with `wanted`, leaving any binding that
    /// has not changed alone rather than tearing it down and building it again.
    func sync(_ wanted: [ShortcutAction: Shortcut]) {
        for (action, registration) in registered where wanted[action] != registration.shortcut {
            UnregisterEventHotKey(registration.ref)
            registered[action] = nil
        }

        let missing = wanted.filter { registered[$0.key] == nil }
        guard !missing.isEmpty else { return }

        installHandler()
        for (action, shortcut) in missing {
            register(action, shortcut)
        }
        let names = registered.keys.map(\.rawValue).sorted().joined(separator: ",")
        Log.core.debug("hotkeys registered=\(names, privacy: .public)")
    }

    func stop() {
        for registration in registered.values {
            UnregisterEventHotKey(registration.ref)
        }
        registered.removeAll()
        if let handler {
            RemoveEventHandler(handler)
        }
        handler = nil
    }

    private func register(_ action: ShortcutAction, _ shortcut: Shortcut) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        // A chord another app already owns is refused. There is nothing to do
        // about it and nothing worth telling the user: the tap still handles the
        // key whenever it can, which is almost always.
        guard status == noErr, let ref else {
            Log.core.notice(
                "hotkey refused action=\(action.rawValue, privacy: .public) status=\(status, privacy: .public)"
            )
            return
        }
        registered[action] = Registration(ref: ref, shortcut: shortcut)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            freeTypistHotKeyCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = ShortcutAction(hotKeyID: id) else { return }
        Log.core.debug("hotkey fired action=\(action.rawValue, privacy: .public)")
        // Hop out of Carbon's dispatch before acting on it. Accepting a
        // suggestion clears it, which unregisters the very hot key being
        // dispatched, and tearing a registration down from inside its own
        // handler is not a thing worth finding the limits of.
        Task { @MainActor [weak self] in
            self?.onAction?(action)
        }
    }
}

/// Must live at file scope: a C function pointer cannot capture context.
/// Carbon dispatches hot keys on the main run loop, so `assumeIsolated` is sound
/// for the same reason it is in `KeyEventTap`.
private func freeTypistHotKeyCallback(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userInfo: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userInfo else { return noErr }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == HotKeyMonitor.signature else { return noErr }

    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated { monitor.fire(id.id) }
    return noErr
}
