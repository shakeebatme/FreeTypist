import AppKit
import ApplicationServices

@MainActor
final class AccessibilityService {
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. macOS only presents it once per app identity;
    /// afterwards the user has to toggle the switch themselves.
    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openSettingsPane() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// TCC identifies an ad-hoc signed app by its code hash, so a rebuild looks
    /// like a different app and silently loses permission. Surfacing the running
    /// path lets the user confirm they authorised the copy that is running.
    var runningAppPath: String { Bundle.main.bundlePath }
}
