import AppKit
import Carbon.HIToolbox

/// Whether macOS is routing keystrokes through *secure event input* right now,
/// and which process asked for it.
///
/// Secure input is the system's answer to keyloggers: while it is on, the
/// window server stops delivering key events to session taps. `HotKeyMonitor`
/// exists because Carbon hot keys are dispatched ahead of that gate and keep
/// firing — but that only settles who gets the Tab key. It says nothing about
/// whether there should be anything to accept, and Accessibility reads are not
/// gated at all: the field under the caret can still be read while it is
/// collecting a password.
///
/// `kAXSecureTextFieldSubrole`, checked in `FocusedTextReader`, catches the
/// AppKit case and only that one. A password field in an Electron app, a login
/// form in a web page, a terminal sitting at a `sudo` prompt — none of them
/// carry the subrole, and every one of them turns secure input on. This is the
/// second defence, and it is the one that covers them.
enum SecureInput {

    /// True while any process on this session holds secure input.
    ///
    /// Cheap enough for the fast pass: it reads a flag the window server keeps,
    /// with no round trip into another process.
    static var isActive: Bool { IsSecureEventInputEnabled() }

    /// The process holding it, when the window server is willing to say.
    ///
    /// `kCGSSessionSecureInputPID` is not a documented key and is not promised
    /// to be there — it is read through the public
    /// `CGSessionCopyCurrentDictionary`, and everything here degrades to "some
    /// app" when it is missing. Nothing decides whether to suggest on the
    /// strength of this; `isActive` alone does that. This is for the sentence
    /// shown to the user, which is worth a great deal when secure input has
    /// been left on by an app that is no longer in front of them.
    static func assertingApplication() -> NSRunningApplication? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? pid_t,
              pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// One line for the status line, or nil when secure input is off.
    static func explanation() -> String? {
        guard isActive else { return nil }
        return summary(assertedBy: assertingApplication()?.localizedName)
    }

    /// The whole story, for the settings window's diagnosis.
    static func diagnosis() -> String? {
        guard isActive else { return nil }
        return detail(assertedBy: assertingApplication()?.localizedName)
    }

    // MARK: - Wording
    //
    // Pure and separate from the system queries above, so what the user is told
    // can be tested without a password prompt on screen.

    static func summary(assertedBy app: String?) -> String {
        guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
            return "Paused: a password is being entered somewhere."
        }
        return "Paused while \(app) is taking a password."
    }

    static func detail(assertedBy app: String?) -> String {
        // The leaked case is the one worth spending words on. An app that turns
        // secure input on and exits without turning it off leaves the whole Mac
        // in this state until something else clears it, and from the outside
        // that is indistinguishable from FreeTypist being broken — which is
        // precisely the report `AppCompatibility` exists to prevent.
        let stray = """
            If nothing on screen is asking for a password, an app has left \
            secure input switched on. Quitting whichever app you last typed a \
            password into usually clears it.
            """
        guard let app = app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else {
            return """
                macOS is in secure input, so an app somewhere is taking a \
                password and FreeTypist is not reading the field under the \
                caret. \(stray)
                """
        }
        return """
            \(app) has switched on secure input to take a password, so \
            FreeTypist is not reading the field under the caret. \(stray)
            """
    }
}
