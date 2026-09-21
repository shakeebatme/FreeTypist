import Foundation

/// Per-app overrides. The rule is that an unset field defers to the global
/// setting *and keeps deferring* — an override has to be distinguishable from
/// a value that merely matches today's default, or changing the global setting
/// later would silently skip every app anyone had ever opened.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

var overrides = AppOverrides()
check("nothing is overridden to begin with", overrides.isEmpty)

// An app nobody has touched defers on everything, and asking about one is not
// the same as creating it.
let untouched = overrides["com.apple.mail"]
check("an untouched app defers on everything", untouched.isEmpty)
check("asking does not create an entry", overrides.isEmpty)
check("no bundle identifier defers too", overrides[nil].isEmpty)

// One field set, the rest still deferring.
var slack = AppOverrides.Settings()
slack.maxWords = 2
slack.emojiSuggestions = true
overrides.set(slack, for: "com.tinyspeck.slackmacgap")
check("the set fields come back",
      overrides["com.tinyspeck.slackmacgap"].maxWords == 2
      && overrides["com.tinyspeck.slackmacgap"].emojiSuggestions == true)
check("the unset ones still defer",
      overrides["com.tinyspeck.slackmacgap"].midLineCompletions == nil
      && overrides["com.tinyspeck.slackmacgap"].showSuggestedFixes == nil)
check("other apps are untouched", overrides["com.apple.mail"].isEmpty)

// False is a real answer, not an absence. This is the case a naive
// implementation gets wrong, because `?? global` on a Bool? is the only thing
// that tells "off" from "unset".
var editor = AppOverrides.Settings()
editor.emojiSuggestions = false
editor.showSuggestedFixes = false
overrides.set(editor, for: "com.microsoft.VSCode")
check("off is stored as off, not as unset",
      overrides["com.microsoft.VSCode"].emojiSuggestions == false)
check("off is not confused with deferring",
      overrides["com.microsoft.VSCode"].emojiSuggestions != nil)

// An entry that overrides nothing is removed, or the list would show an app
// with nothing to say — which reads as a setting that failed to save.
overrides.set(AppOverrides.Settings(), for: "com.tinyspeck.slackmacgap")
check("an empty entry is dropped", overrides.apps["com.tinyspeck.slackmacgap"] == nil)
check("the others survive it", overrides.apps["com.microsoft.VSCode"] != nil)

overrides.remove("com.microsoft.VSCode")
check("removing takes the app off the list", overrides.isEmpty)

// What the row says about itself.
check("an empty summary says so", AppOverrides.Settings().summary == "No changes")
check("a summary names what changed", slack.summary.contains("2 words") && slack.summary.contains("emoji"))
check("a summary distinguishes off from on", editor.summary.contains("no emoji"))

// MARK: Round trip

let suite = "ft.overrides.tests.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suite) else {
    print("FAIL could not make a test defaults suite"); exit(1)
}
check("an empty store has no overrides", AppOverrides.load(from: defaults).isEmpty)

var saved = AppOverrides()
saved.set(slack, for: "com.tinyspeck.slackmacgap")
saved.set(editor, for: "com.microsoft.VSCode")
saved.save(to: defaults)

let loaded = AppOverrides.load(from: defaults)
check("overrides survive the round trip", loaded == saved)
check("and so does the difference between off and unset",
      loaded["com.microsoft.VSCode"].emojiSuggestions == false
      && loaded["com.microsoft.VSCode"].maxWords == nil)

defaults.set(Data([0x09, 0x09]), forKey: "ft.appOverrides")
check("unreadable data means no overrides, not a crash",
      AppOverrides.load(from: defaults).isEmpty)

defaults.removePersistentDomain(forName: suite)

print(failures == 0 ? "\nAll override cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
