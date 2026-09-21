import AppKit

/// Two tables that fail silently when they are wrong.
///
/// A System Settings pane identifier that does not exist opens System Settings
/// at whatever it last showed, and macOS reports nothing — so a mistyped one
/// looks like a button that does nothing. And a duplicate key in a Swift
/// dictionary literal is a runtime crash, not a compile error, so the emoji
/// table has to be *read* by something before a user reads it.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// MARK: System Settings panes

check("every pane is covered", SystemSettings.allCases.count == 3)
for pane in SystemSettings.allCases {
    check("\(pane.title): builds a URL", pane.url != nil)
    check("\(pane.title): uses the settings scheme",
          pane.url?.scheme == "x-apple.systempreferences")
    check("\(pane.title): names a pane", !pane.rawValue.isEmpty
          && pane.rawValue.hasPrefix("com.apple.")
          && !pane.rawValue.contains(" "))
    check("\(pane.title): has a label", !pane.title.isEmpty)
}
check("the identifiers are distinct",
      Set(SystemSettings.allCases.map(\.rawValue)).count == SystemSettings.allCases.count)

// MARK: Emoji shortcodes

// Merely reading it is the duplicate-key check: a repeated key traps here
// rather than in front of a user.
let table = HeuristicProvider.emojiTable
check("the table is substantial", table.count >= 100)

for (code, glyph) in table {
    check("\(code) opens with a colon", code.hasPrefix(":"))
    check("\(code) is lowercase with no spaces",
          code == code.lowercased() && !code.contains(" "))
    check("\(code) has more than its colon", code.count > 1)
    check("\(code) maps to something", !glyph.isEmpty)
    // A shortcode that expands to plain text would be silently inserting
    // letters where the user asked for a picture.
    check("\(code) maps to a glyph, not text",
          glyph.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value > 0x2000 })
}

// The ones the README promises by name.
for promised in [":rocket", ":fire", ":check", ":thumbsup"] {
    check("\(promised) is offered", table[promised] != nil)
}

print(failures == 0 ? "\nAll system-link and emoji cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
