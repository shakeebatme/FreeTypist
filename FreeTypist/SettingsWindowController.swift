import AppKit
import SwiftUI

/// Owns the Settings window directly.
///
/// SwiftUI's `Settings` scene assumes a regular app. This one is `LSUIElement`,
/// so when the user clicks the menu bar item the app is *not* active — and
/// `NSApp.sendAction(showSettingsWindow:)` travels a responder chain with no
/// target, so nothing opens at all. Activating first does not fix it either,
/// because activation is asynchronous and the action is dispatched immediately.
///
/// Holding the window ourselves removes the guesswork: create it, activate, and
/// order it front.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present(
        model: AppModel,
        preferences: Preferences,
        coordinator: CompletionCoordinator
    ) {
        if let window {
            show(window)
            return
        }

        let controller = NSHostingController(
            rootView: SettingsView(
                model: model,
                preferences: preferences,
                coordinator: coordinator
            )
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "FreeTypist Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 620))
        window.setFrameAutosaveName("FreeTypistSettings")
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        show(window)
    }

    private func show(_ window: NSWindow) {
        // An accessory app cannot take keyboard focus: the window appears in
        // front but never becomes key, so typing still goes to the app behind it
        // (measured: AXMain true, AXFocused false). Becoming a regular app for
        // as long as a window is open is the standard remedy, and costs only a
        // temporary Dock icon.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        // `activate()` alone follows cooperative activation and can be declined,
        // leaving the window visible but unfocused. The older call overrides
        // that, which is what a settings window opened from a menu bar item
        // needs.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        // "Will close" fires while the window is still visible, so checking
        // immediately always finds it and the app stays in the Dock. Check on a
        // later turn, and ignore this window explicitly.
        let closing = notification.object as? NSWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Only ordinary titled windows keep the app in the Dock. The menu
            // bar extra owns an `NSStatusBarWindow`, which is neither a panel
            // nor titled, and counting it left the Dock icon behind forever.
            let blocking = NSApp.windows.filter { window in
                window !== closing
                    && window.isVisible
                    && window.level == .normal
                    && window.styleMask.contains(.titled)
            }
            guard blocking.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
