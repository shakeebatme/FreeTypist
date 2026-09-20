import AppKit

/// Regression check for ":rocket" losing its emoji to a model completion.
///
/// The coordinator paints the heuristic answer immediately and then asks the
/// model, which presents unconditionally when it lands — so whichever arrives
/// last wins. A spelling fix was safe by accident, because a misspelled word
/// sets `suppressOnTypo` and closes the model pass. A shortcode is spelled
/// correctly, so nothing held the model off and 🚀 was overwritten a few
/// hundred milliseconds after it appeared.
///
/// The coordinator now holds the model off for any *replacement*. That makes
/// `isCorrection` load-bearing, so these cases pin which suggestions carry it.

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
    let heuristic = HeuristicProvider()

    // Every shipped shortcode has to come back as a replacement, naming the
    // shortcode it replaces. An emoji offered as a plain continuation would
    // append 🚀 after the text rather than swapping it in.
    let shortcodes = [":rocket", ":smile", ":heart", ":thumbsup", ":fire", ":100", ":ship"]
    var notReplacements: [String] = []
    var wrongSpan: [String] = []
    for code in shortcodes {
        guard let suggestion = heuristic.suggestSync(before: "Ship it \(code)", after: "") else {
            notReplacements.append("\(code) -> no suggestion")
            continue
        }
        if !suggestion.isCorrection {
            notReplacements.append("\(code) -> \(suggestion.text) (not a replacement)")
        } else if suggestion.replacing != code {
            wrongSpan.append("\(code) -> replaces \(suggestion.replacing.debugDescription)")
        }
    }
    Harness.check("every shortcode is a replacement", notReplacements.isEmpty)
    for entry in notReplacements { print("      \(entry)") }
    Harness.check("each replaces exactly its own shortcode", wrongSpan.isEmpty)
    for entry in wrongSpan { print("      \(entry)") }

    // The precondition that made this bug shortcode-specific: the spell checker
    // has no opinion about ":rocket", so `suppressOnTypo` never fires for it and
    // the model pass was left open.
    Harness.check("a shortcode is not a typo, so the typo guard cannot protect it",
                  !WordBoundary.isMisspelled(WordBoundary.currentWord(in: "Ship it :rocket")))

    // A spelling fix is a replacement too, and must stay one: it is now held
    // safe by `isCorrection` rather than by `suppressOnTypo` alone.
    if let fix = heuristic.suggestSync(before: "teh", after: "") {
        Harness.check("a spelling fix is a replacement", fix.isCorrection)
        Harness.check("the fix replaces the misspelled word", fix.replacing == "teh")
    } else {
        Harness.check("a spelling fix is offered at all", false)
    }

    // The other side of the same switch. An ordinary completion must *not*
    // claim to be a replacement, or holding the model off would silently
    // disable it for the phrase and vocabulary cases it is meant to improve.
    let completions = ["Thanks for", "unfortun", "I wanted to"]
    var mislabelled: [String] = []
    for text in completions {
        guard let suggestion = heuristic.suggestSync(before: text, after: "") else { continue }
        if suggestion.isCorrection {
            mislabelled.append("\(text.debugDescription) -> replaces \(suggestion.replacing.debugDescription)")
        }
    }
    Harness.check("an ordinary completion is not a replacement", mislabelled.isEmpty)
    for entry in mislabelled { print("      \(entry)") }

    // Switching emoji off has to leave the shortcode alone entirely, rather
    // than falling through to a correction for it.
    let off = heuristic.suggestSync(before: "Ship it :rocket", after: "", showFixes: true, emoji: false)
    Harness.check("emoji off means no emoji replacement", off?.replacing != ":rocket")

    print(Harness.failures == 0 ? "\nAll heuristic cases passed." : "\n\(Harness.failures) FAILED")
    exit(Harness.failures == 0 ? 0 : 1)
}

run()
