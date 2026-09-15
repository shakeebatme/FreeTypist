import AppKit
import SwiftUI

/// Presents onboarding in its own window.
///
/// A plain `NSWindow` rather than a SwiftUI scene: this app has no regular
/// window scene, and `MenuBarExtra` alone gives nothing to attach one to.
@MainActor
final class OnboardingWindow {
    private var window: NSWindow?

    func present(_ onboarding: OnboardingModel, models: ModelRepository) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView(onboarding: onboarding, models: models)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to FreeTypist"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
