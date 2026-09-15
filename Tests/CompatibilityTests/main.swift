import Foundation

/// Locks in which apps are declared unsupported and why. The table is the
/// user-visible promise — an app silently dropping off it would look like the
/// original bug ("works in Safari, not in Ghostty") all over again.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// Measured: caret pinned at {0,0} and no parameterized attributes at all.
check("Ghostty is declared unsupported",
      AppCompatibility.isKnownUnsupported("com.mitchellh.ghostty"))
check("Ghostty's debug build too",
      AppCompatibility.isKnownUnsupported("com.mitchellh.ghostty.debug"))

// Terminals that do answer bounds queries must not be swept up with it.
for supported in ["com.apple.Terminal", "com.googlecode.iterm2"] {
    check("\(supported) stays supported", !AppCompatibility.isKnownUnsupported(supported))
}

// Apps verified working this session.
for supported in ["com.apple.mail", "com.apple.Safari", "com.apple.TextEdit"] {
    check("\(supported) stays supported", !AppCompatibility.isKnownUnsupported(supported))
}

check("no bundle identifier is not a limitation", !AppCompatibility.isKnownUnsupported(nil))

// The reason has to be specific enough to act on; a bare "unsupported" was the
// failure mode being fixed.
if let limitation = AppCompatibility.limitation(for: "com.mitchellh.ghostty") {
    // Both strings are shown on their own, so each has to name its own app.
    check("summary names the app", limitation.summary.contains("Ghostty"))
    check("detail names the app", limitation.detail.contains("Ghostty"))
    check("detail explains the missing piece", limitation.detail.contains("caret"))
    check("detail points somewhere that works", limitation.detail.contains("Terminal.app"))
    check("detail is one paragraph", !limitation.detail.contains("\n"))
    // Menu items clip rather than wrap. Measured against the live menu: past
    // roughly forty characters the text is cut off mid-word.
    check("summary fits the menu bar", limitation.summary.count <= 40)
} else {
    check("Ghostty has a limitation record", false)
}

// Ghostty is still a terminal for prompt-stripping purposes; the two tables are
// independent and must not be conflated.
check("Ghostty is still classed as a terminal", TerminalContext.isTerminal("com.mitchellh.ghostty"))

print(failures == 0 ? "\nAll compatibility cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
