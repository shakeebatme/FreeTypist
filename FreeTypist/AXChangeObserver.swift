import AppKit
import ApplicationServices

/// Watches the focused app for text, caret and focus changes, so the completion
/// loop can react when something actually happens instead of asking every so
/// often.
///
/// A poll still runs behind this, slower. Notifications are the fast, common
/// path; the poll is what keeps the uncommon path working:
///
/// - Nothing notifies us about Accessibility permission being granted or
///   revoked, so `syncPermissionState` has no event to hang off.
/// - Not every app posts these. Measured working in Safari and TextEdit; the
///   apps already known to expose little or nothing (terminal emulators, some
///   Electron hosts) are exactly the ones likely to stay silent.
///
/// Registration is per-process, so the observer is torn down and rebuilt as the
/// frontmost app changes.
@MainActor
final class AXChangeObserver {
    /// Called on the main actor when the focused text may have changed. Fires
    /// far more often than the text really changes — Safari posts two
    /// `AXValueChanged` per keystroke plus a trailing `AXSelectedTextChanged` —
    /// so the callback must be debounced.
    var onChange: (() -> Void)?

    /// Called when the field moved or went out of view without its text
    /// changing. Separate from `onChange` on purpose: the suggestion is still
    /// the right one, so it must not be regenerated, but where it is drawn is
    /// now wrong and the caret rect has to be taken from the app again.
    var onDisplacement: ((Displacement) -> Void)?

    enum Displacement {
        /// The window is being dragged or resized. The field still has focus;
        /// only the caret rect is stale.
        case moved
        /// The field is no longer on screen to draw over: the app was hidden or
        /// deactivated, the window was minimised, or focus left the window.
        case lost
    }

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var appElement: AXUIElement?
    private var observedField: AXUIElement?
    private var waiters: [Waiter] = []
    /// Handle for the block-based workspace registration. `removeObserver(self)`
    /// does nothing for one of these — the block is the observer, and this is
    /// its only handle — so `stop()` did not stop: an app activated during
    /// teardown still reached `attach` and built a fresh AX observer.
    private var activationToken: NSObjectProtocol?

    private let fieldNotifications = [
        kAXValueChangedNotification,
        kAXSelectedTextChangedNotification,
    ]

    /// Registered on the application element, which receives these on behalf of
    /// every window it owns — there is no need to chase whichever window happens
    /// to hold the caret. None of them mean the text changed, so they are routed
    /// away from `signal` and the debounced completion pass it drives.
    private let displacementNotifications: [String: Displacement] = [
        kAXWindowMovedNotification: .moved,
        kAXWindowResizedNotification: .moved,
        kAXWindowMiniaturizedNotification: .lost,
        kAXApplicationHiddenNotification: .lost,
        kAXApplicationDeactivatedNotification: .lost,
        kAXFocusedWindowChangedNotification: .lost,
    ]

    func start() {
        guard activationToken == nil else { return }
        // `[weak self]` on the outer closure, where it is actually a weak
        // capture: on the inner one the outer closure holds `self` strongly to
        // build it, which is how this object outlived every `stop()`.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.attach(to: pid)
                self?.signal("appActivated")
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            attach(to: front.processIdentifier)
        }
    }

    func stop() {
        if let activationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(activationToken)
            self.activationToken = nil
        }
        detach()
        resumeWaiters(changed: false)
    }

    /// Re-reads which element has focus and moves the field notifications onto
    /// it. Called when the app says focus moved, and by the coordinator after it
    /// has read a new field, since a focus change inside one app does not always
    /// produce a notification we saw.
    func refocus(on element: AXUIElement?) {
        guard let observer else { return }
        // The coordinator calls this for every field it reads, which is every
        // keystroke. Re-registering the same element each time is pure churn: a
        // remove and two adds of synchronous IPC into the target app, and a
        // window between them in which a change goes unreported.
        if let observedField, let element, CFEqual(observedField, element) { return }
        if observedField == nil, element == nil { return }
        if let observedField {
            for note in fieldNotifications {
                AXObserverRemoveNotification(observer, observedField, note as CFString)
            }
        }
        observedField = element
        guard let element else { return }
        // The context pointer must be supplied here, not added later: a repeat
        // registration for the same notification on the same element answers
        // `notificationAlreadyRegistered` and keeps the context from the first
        // call. Registering with nil first would leave the callback unable to
        // find this object, and field changes would go silently unreported.
        let context = Unmanaged.passUnretained(self).toOpaque()
        for note in fieldNotifications {
            // An app that will not take the registration simply stays on the
            // poll; there is nothing useful to do about it here.
            AXObserverAddNotification(observer, element, note as CFString, context)
        }
    }

    // MARK: - Waiting for one change

    /// Suspends until the focused text changes, or until `timeout` elapses.
    /// Returns true when a change actually arrived.
    ///
    /// This is what lets an insertion be confirmed by being told, rather than by
    /// re-reading the field on a timer and hoping the app has caught up.
    func nextChange(within timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation)
            waiters.append(waiter)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                waiter.finish(false)
            }
        }
    }

    private func resumeWaiters(changed: Bool) {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.finish(changed) }
    }

    fileprivate func signal(_ name: String = "?") {
        resumeWaiters(changed: true)
        onChange?()
    }

    /// The window under the caret moved, or the field stopped being visible.
    fileprivate func displaced(_ kind: Displacement) {
        onDisplacement?(kind)
    }

    fileprivate func displacement(for notification: String) -> Displacement? {
        displacementNotifications[notification]
    }

    /// Focus moved within the app, so the field notifications belong somewhere
    /// else now.
    fileprivate func focusMoved() {
        guard let appElement else { return signal("focusMoved-noapp") }
        refocus(on: AX.element(appElement, kAXFocusedUIElementAttribute as String))
        signal("focusMoved")
    }

    // MARK: - Per-process registration

    private func attach(to pid: pid_t) {
        guard pid != observedPID else { return }
        detach()
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, axChangeObserverCallback, &created) == .success,
              let created else { return }

        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(
            created, app, kAXFocusedUIElementChangedNotification as CFString, context
        )
        for note in displacementNotifications.keys {
            AXObserverAddNotification(created, app, note as CFString, context)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes
        )

        observer = created
        observedPID = pid
        appElement = app
        refocus(on: AX.element(app, kAXFocusedUIElementAttribute as String))
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes
            )
        }
        observer = nil
        observedPID = nil
        appElement = nil
        observedField = nil
    }
}

/// Holds one suspended caller. A continuation must be resumed exactly once, and
/// two things race to do it: the change itself and the timeout.
private final class Waiter {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @MainActor
    func finish(_ changed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: changed)
    }
}

/// Must live at file scope: a C function pointer cannot capture context.
/// AX observer callbacks are delivered on the run loop they were registered
/// with, which is the main one, so `assumeIsolated` is sound.
private func axChangeObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let watcher = Unmanaged<AXChangeObserver>.fromOpaque(context).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        if name == (kAXFocusedUIElementChangedNotification as String) {
            watcher.focusMoved()
        } else if let displacement = watcher.displacement(for: name) {
            watcher.displaced(displacement)
        } else {
            watcher.signal(name)
        }
    }
}
