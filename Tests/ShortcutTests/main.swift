import AppKit
import CoreGraphics

/// Covers the two pure pieces of shortcut handling: matching a keystroke to a
/// binding, and splitting a suggestion one word at a time.

@MainActor
enum Harness {
    static var failures = 0
    static func check(_ label: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }
}

@MainActor
func run() {
    // MARK: Matching

    let tab = Shortcut(keyCode: Shortcut.tab)
    Harness.check("plain Tab matches", tab.matches(KeyStroke(keyCode: 48, flags: [])))
    // Shift-Tab is back-tab in most apps; it must not be swallowed as "Tab".
    Harness.check("Shift-Tab does not match plain Tab",
                  !tab.matches(KeyStroke(keyCode: 48, flags: .maskShift)))

    let chord = Shortcut(keyCode: Shortcut.grave, modifiers: [.maskControl, .maskAlternate, .maskCommand])
    Harness.check("full chord matches",
                  chord.matches(KeyStroke(keyCode: 50, flags: [.maskControl, .maskAlternate, .maskCommand])))
    Harness.check("partial chord does not match",
                  !chord.matches(KeyStroke(keyCode: 50, flags: [.maskControl])))
    // Caps lock and numeric-pad bits must not defeat a match.
    Harness.check("irrelevant flags ignored",
                  tab.matches(KeyStroke(keyCode: 48, flags: [.maskAlphaShift, .maskNumericPad])))

    Harness.check("defaults put full completion on the key above Tab",
                  ShortcutAction.fullCompletion.defaultShortcut?.keyCode == Shortcut.grave)
    Harness.check("default labels render", ShortcutAction.forceActivate.defaultShortcut?.display == "⌃`")

    // MARK: Word splitting

    typealias Split = Suggestion
    var result = Split.splitFirstWord(" getting back to me.")
    Harness.check("takes leading space plus one word", result.head == " getting" && result.tail == " back to me.")

    result = Split.splitFirstWord(" back to me.", includeTrailingSpace: true)
    Harness.check("trailing space option takes the gap too", result.head == " back ")

    // Punctuation is a separate press unless asked for, so "me" and "." differ.
    result = Split.splitFirstWord(" me.")
    Harness.check("punctuation excluded by default", result.head == " me" && result.tail == ".")

    result = Split.splitFirstWord(" me.", includeTrailingPunctuation: true)
    Harness.check("punctuation included on request", result.head == " me.")

    result = Split.splitFirstWord("hello")
    Harness.check("single word leaves no tail", result.head == "hello" && result.tail.isEmpty)

    // Punctuation inside a word closes nothing, so Tab must not stop on it.
    // Each of these put a fragment into the document one press at a time.
    let joined: [(String, String)] = [
        (" don't worry about it", " don't"),
        (" I'll follow up", " I'll"),
        (" well-known issue", " well-known"),
        (" 1,000 units", " 1,000"),
        (" and/or the other", " and/or"),
    ]
    let broken = joined.filter { Split.splitFirstWord($0.0).head != $0.1 }
    Harness.check("punctuation inside a word is part of it", broken.isEmpty)
    for (input, expected) in broken {
        Harness.check("  \(input) -> \(Split.splitFirstWord(input).head), wanted \(expected)", false)
    }

    // The other direction still holds: a mark that ends a word is its own press.
    result = Split.splitFirstWord(" shortly.")
    Harness.check("punctuation that ends a word still splits",
                  result.head == " shortly" && result.tail == ".")

    // A continuation may open on punctuation — the stock phrase after
    // "as discussed" does. The first character of a word never splits it, or
    // the head comes back empty and nothing advances.
    result = Split.splitFirstWord(", I'll send the next update shortly.")
    Harness.check("a leading mark is its own head", result.head == ",")
    result = Split.splitFirstWord("'ll follow up")
    Harness.check("a word opening on a mark still advances", result.head == "'ll")

    // One number cannot be an Accessibility range, a run of backspaces and a
    // text-marker walk at once. They agree on ASCII and part company on the
    // first decomposed character, so the replaced text is carried and each
    // consumer measures it in its own units.
    let decomposed = Suggestion(text: "cafes", replacing: "cafe\u{0301}", source: .heuristic)
    Harness.check("a decomposed word is longer as an Accessibility range",
                  decomposed.replacedRangeLength == 5)
    Harness.check("and shorter in key presses", decomposed.replacedCharacterCount == 4)

    let ascii = Suggestion(text: "receive", replacing: "recieve", source: .heuristic)
    Harness.check("plain text measures the same either way",
                  ascii.replacedRangeLength == ascii.replacedCharacterCount)
    Harness.check("a correction knows it is one", ascii.isCorrection)
    Harness.check("a completion replaces nothing",
                  !Suggestion(text: " there", source: .model).isCorrection)

    // Events we post must carry no modifiers. A new CGEvent is seeded from the
    // live keyboard, so anything the user is holding when the accept fires rides
    // along with the text — and two of the shipped shortcuts are chords, so a
    // modifier being down at that moment is the ordinary case.
    let source = CGEventSource(stateID: .combinedSessionState)
    if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
        event.flags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        SyntheticEvent.stamp(event)
        Harness.check("stamping clears inherited modifiers",
                      event.flags.intersection(Shortcut.relevantModifiers).isEmpty)
        Harness.check("stamping marks the event as ours", SyntheticEvent.isOurs(event))
    } else {
        Harness.check("could not build a CGEvent to check stamping", false)
    }
    if let untouched = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
        Harness.check("an unstamped event is not mistaken for ours",
                      !SyntheticEvent.isOurs(untouched))
    }

    print(Harness.failures == 0 ? "\nAll shortcut cases passed." : "\n\(Harness.failures) FAILED")
    exit(Harness.failures == 0 ? 0 : 1)
}

run()
