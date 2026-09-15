import AppKit

/// Regression check: a hand-written correction table was replaced with
/// NSSpellChecker. The replacement must cover at least what the table did, and
/// must not "fix" words that are already correct.

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
    // Every entry from the table that was removed.
    let table = [
        "recieve": "receive", "teh": "the", "adn": "and", "seperate": "separate",
        "definately": "definitely", "occured": "occurred", "accomodate": "accommodate",
        "neccessary": "necessary", "recomend": "recommend", "existance": "existence",
        "beleive": "believe", "acheive": "achieve", "wich": "which", "thier": "their",
        "untill": "until", "arguement": "argument", "publically": "publicly",
    ]

    var covered = 0
    var wrong: [String] = []
    for (typo, expected) in table.sorted(by: { $0.key < $1.key }) {
        let fix = WordBoundary.correction(for: typo)
        if fix?.caseInsensitiveCompare(expected) == .orderedSame {
            covered += 1
        } else {
            wrong.append("\(typo) -> \(fix ?? "nil") (table said \(expected))")
        }
    }
    Harness.check("spell checker covers the removed table (\(covered)/\(table.count))", covered == table.count)
    for entry in wrong { print("      \(entry)") }

    // Must not touch correct words — a false correction is worse than none.
    let correct = ["receive", "the", "separate", "definitely", "necessary", "Shakeeb", "FreeTypist"]
    let falsePositives = correct.filter { WordBoundary.correction(for: $0) != nil }
    Harness.check("no false corrections on correct words", falsePositives.isEmpty)
    for word in falsePositives { print("      flagged: \(word) -> \(WordBoundary.correction(for: word) ?? "")") }

    // Beyond the table: arbitrary typos the hardcoded list could never cover.
    let extras = ["stnadup", "tommorow", "mangement", "sucessful"]
    let handled = extras.filter { WordBoundary.correction(for: $0) != nil }
    Harness.check("handles typos outside the old table (\(handled.count)/\(extras.count))", handled.count >= 3)
    for word in extras {
        print("      \(word) -> \(WordBoundary.correction(for: word) ?? "nil")")
    }

    Harness.check("caret-after-complete-word still works", WordBoundary.caretEndsCompleteWord("time to"))
    Harness.check("caret-after-fragment still works", !WordBoundary.caretEndsCompleteWord("unfortun"))

    // The case that put a space inside a word: the spell checker does not flag
    // short fragments, so a caret partway through one was reported as ending a
    // finished word and "…reaching out. Ar" was completed to "Ar wa is doing
    // well." Asking the completion list as well separates a fragment from a
    // short word that happens to be finished.
    for fragment in ["Thank you for reaching out. Ar", "Th", "Hi Chr", "co", "e"] {
        Harness.check("a short fragment does not end a word (\(fragment))",
                      !WordBoundary.caretEndsCompleteWord(fragment))
    }
    for finished in ["time to", "this is", "here is an", "I", "Hi Christine",
                     "don't", "it's well-known", "we use Kubernetes", "attached the PDF"] {
        Harness.check("a finished word still ends one (\(finished))",
                      WordBoundary.caretEndsCompleteWord(finished))
    }

    // Nothing to attach to: a continuation after a space or a mark brings its
    // own spacing, so neither is a word boundary question.
    Harness.check("a caret after a space ends no word", !WordBoundary.caretEndsCompleteWord("time to "))
    Harness.check("a caret after punctuation ends no word", !WordBoundary.caretEndsCompleteWord("Hi Christine,"))

    // A word the user is partway through is not a mistake. Getting this wrong
    // cost both halves of the engine at once: `suppressOnTypo` closed the model
    // pass for every partial word of four letters or more, and the heuristic
    // offered a *correction* for one — "appre" was struck through and offered
    // "apple", which Tab then accepted, on the way to "appreciate".
    let unfinished = ["appre", "impl", "unfortun", "documen", "tomorr", "apprecia", "recomm"]
    let flagged = unfinished.filter { WordBoundary.isMisspelled($0) }
    Harness.check("a half-typed word is not a typo", flagged.isEmpty)
    for word in flagged { print("      flagged mid-type: \(word)") }

    let hijacked = unfinished.filter { WordBoundary.correction(for: $0) != nil }
    Harness.check("no fix is offered for a half-typed word", hijacked.isEmpty)
    for word in hijacked { print("      \(word) -> \(WordBoundary.correction(for: word) ?? "")") }

    // The other direction: the separation has to keep working for real typos,
    // including the ones the curated table does not list.
    let realTypos = ["recieve", "seperate", "invesigate", "stnadup", "tommorow", "sucessful"]
    let missed = realTypos.filter { !WordBoundary.isMisspelled($0) }
    Harness.check("a real typo is still a typo", missed.isEmpty)
    for word in missed { print("      missed: \(word)") }

    Harness.check("unfinished is what separates them",
                  WordBoundary.isUnfinished("appre") && !WordBoundary.isUnfinished("recieve"))

    print(Harness.failures == 0 ? "\nAll spell cases passed." : "\n\(Harness.failures) FAILED")
    exit(Harness.failures == 0 ? 0 : 1)
}

run()
