import Foundation

/// macOS's own inline predictions and autocorrect, which collide with ours.
///
/// Two separate global settings are involved and both matter:
/// `NSAutomaticInlinePredictionEnabled` draws grey text like ours, and
/// `NSAutomaticSpellingCorrectionEnabled` shows the autocorrect bubble that
/// appears under a typo — directly on top of our strikethrough fix.
///
/// These live in `NSGlobalDomain`, so changing them affects every app. Nothing
/// here is ever changed automatically; it is offered as a toggle.
enum SystemTextSuggestions {
    private static let keys = [
        "NSAutomaticInlinePredictionEnabled",
        "NSAutomaticSpellingCorrectionEnabled",
    ]

    /// True while anything that could conflict is still switched on. Absent means
    /// the system default, which is on.
    static var isEnabled: Bool {
        keys.contains { key in
            guard let value = CFPreferencesCopyValue(
                key as CFString, kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            ) as? Bool else { return true }
            return value
        }
    }

    static func setEnabled(_ enabled: Bool) {
        for key in keys {
            CFPreferencesSetValue(
                key as CFString, enabled as CFBoolean,
                kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }
}
