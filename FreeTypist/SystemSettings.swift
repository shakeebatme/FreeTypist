import AppKit

/// The System Settings panes FreeTypist sends people to.
///
/// Each permission has one, and the identifiers are neither guessable nor
/// checkable: a wrong one opens System Settings at whatever it was last
/// showing, which reads as the button doing nothing. Keeping them in one place
/// with a test over their shape is the cheapest guard available — the strings
/// are not validated by the compiler and macOS reports no error for a pane
/// that does not exist.
enum SystemSettings: String, CaseIterable {
    case accessibility = "com.apple.preference.security?Privacy_Accessibility"
    case screenRecording = "com.apple.preference.security?Privacy_ScreenCapture"
    /// Where launch-at-login is really controlled. `SMAppService.register()`
    /// can be overruled here, and when it is, the app's own switch looks
    /// broken because nothing it does will stick.
    case loginItems = "com.apple.LoginItems-Settings.extension"

    var url: URL? { URL(string: "x-apple.systempreferences:\(rawValue)") }

    /// What this pane is for, so a caller can label the button without knowing
    /// the identifier.
    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .loginItems: "Login Items"
        }
    }

    @discardableResult
    func open() -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}
