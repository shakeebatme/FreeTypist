import AppKit

/// Exists for one reason: giving the engine a chance to release Metal resources
/// before the process exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@Sendable () -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
