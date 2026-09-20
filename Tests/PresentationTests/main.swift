import AppKit

/// Which way a suggestion is drawn.
///
/// The rule exists because ghost text is opaque and sits in another app's
/// window: drawn at a caret with text after it, the user's own words and the
/// suggestion are superimposed and neither can be read. `midLineCompletions`
/// is the preference that makes that reachable, so every case where something
/// is underneath has to land on the pill instead.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

typealias Presentation = SuggestionOverlayController.Presentation

// MARK: The case this rule was written for

check("mid-line does not draw ghost text over the line",
      Presentation.choose(isCorrection: false, hasCaretRect: true,
                          hasStrikeRect: false, atLineEnd: false) == .pill)

check("end of line still draws inline",
      Presentation.choose(isCorrection: false, hasCaretRect: true,
                          hasStrikeRect: false, atLineEnd: true) == .inline)

// MARK: What was already true and must stay true

check("no caret geometry falls back to the pill",
      Presentation.choose(isCorrection: false, hasCaretRect: false,
                          hasStrikeRect: false, atLineEnd: true) == .pill)

check("a correction with both rects is drawn where the word sits",
      Presentation.choose(isCorrection: true, hasCaretRect: true,
                          hasStrikeRect: true, atLineEnd: true) == .correction)

// A correction rewrites a word that is already on screen, so it is mid-line by
// definition. That must not route it to the pill: it has a strike rect, which
// is the whole point — it draws through the word rather than over the line.
check("a correction is still drawn in place when the caret is mid-line",
      Presentation.choose(isCorrection: true, hasCaretRect: true,
                          hasStrikeRect: true, atLineEnd: false) == .correction)

// Without somewhere to strike, a correction has nothing to point at.
for (caret, strike) in [(true, false), (false, true), (false, false)] {
    check("a correction missing a rect falls back (caret: \(caret), strike: \(strike))",
          Presentation.choose(isCorrection: true, hasCaretRect: caret,
                              hasStrikeRect: strike, atLineEnd: true) == .pill)
}

// MARK: Nothing but a correction is ever drawn as one

for caret in [true, false] {
    for strike in [true, false] {
        for end in [true, false] {
            let chosen = Presentation.choose(isCorrection: false, hasCaretRect: caret,
                                             hasStrikeRect: strike, atLineEnd: end)
            check("a plain completion is never a correction (\(caret), \(strike), \(end))",
                  chosen != .correction)
            // The one invariant worth stating outright: inline is reachable
            // only with geometry to draw at and an empty rest of line.
            if chosen == .inline {
                check("inline implies a caret and the end of a line (\(caret), \(strike), \(end))",
                      caret && end)
            }
        }
    }
}

// MARK: The counter beside a suggestion that is one of several

typealias Overlay = SuggestionOverlayController

// A lone suggestion is not one of several, and "1 of 1" on every completion
// would be noise at the caret.
check("a single suggestion carries no counter",
      Overlay.positionBadge(index: 0, total: 1) == nil)
check("no suggestions carry no counter",
      Overlay.positionBadge(index: 0, total: 0) == nil)

check("the counter is one-based", Overlay.positionBadge(index: 0, total: 3) == "1/3")
check("the second of three reads 2/3", Overlay.positionBadge(index: 1, total: 3) == "2/3")
check("the last of three reads 3/3", Overlay.positionBadge(index: 2, total: 3) == "3/3")

// Cycling is modular, so an index can only ever be in range — but a counter
// that read "4/3" would be worse than none, so it is refused rather than
// trusted.
check("an index past the end carries no counter",
      Overlay.positionBadge(index: 3, total: 3) == nil)
check("a negative index carries no counter",
      Overlay.positionBadge(index: -1, total: 3) == nil)

print(failures == 0 ? "\nAll presentation cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
