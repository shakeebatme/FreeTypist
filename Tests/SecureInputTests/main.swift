import Foundation

/// What the user is told while secure input is on.
///
/// The system half of `SecureInput` — `IsSecureEventInputEnabled` and the
/// session dictionary — cannot be exercised without a password prompt on
/// screen, so what is locked in here is the half that can: that there is always
/// a sentence, that it names the app when the window server named one, and that
/// it never claims to know which app when it does not.
///
/// The stray-secure-input hint is the load-bearing part. An app that turns
/// secure input on and exits without turning it off leaves the whole Mac in
/// this state, and from the outside that is indistinguishable from FreeTypist
/// being broken.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// Named: the app is the most useful thing on the line, so it goes in it.
let named = SecureInput.summary(assertedBy: "1Password")
check("summary names the app", named.contains("1Password"))
check("summary says it is paused", named.lowercased().contains("paused"))

// Unnamed: `kCGSSessionSecureInputPID` is undocumented and may simply not be
// there. Still a sentence, and still no guess at a name.
for unknown in [nil, "", "   "] {
    let summary = SecureInput.summary(assertedBy: unknown)
    check("summary without a name is not empty (\(unknown ?? "nil"))", !summary.isEmpty)
    check("summary without a name says password (\(unknown ?? "nil"))",
          summary.lowercased().contains("password"))
}

// The detail carries the recovery hint in both shapes, because the case that
// needs it most is the one where no app can be named.
for app in ["Terminal", nil] {
    let detail = SecureInput.detail(assertedBy: app)
    check("detail explains what to do (\(app ?? "nil"))",
          detail.contains("left secure input") || detail.contains("left secure input switched on"))
    check("detail says FreeTypist is not reading the field (\(app ?? "nil"))",
          detail.contains("not reading the field"))
}

check("detail names the app when there is one",
      SecureInput.detail(assertedBy: "Terminal").contains("Terminal"))

// Folded onto one line by the `\` continuations in the source; a stray newline
// would wrap badly in the settings row.
for line in [SecureInput.summary(assertedBy: "Terminal"), SecureInput.detail(assertedBy: nil)] {
    check("no hard line breaks in \"\(line.prefix(24))…\"", !line.contains("\n"))
}

print(failures == 0 ? "\nAll secure-input cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
