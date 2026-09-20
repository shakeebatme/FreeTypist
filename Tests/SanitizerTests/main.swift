import AppKit
@MainActor func run() {
    let cases: [(raw: String, before: String, expect: String?)] = [
        // Base checkpoints open a new word with a space of their own. The raw
        // here used to have none, from when the catalogue was instruction-tuned
        // models, which do not. Measured on the bench prompts: this exact
        // `before` now yields " write to us…", space included.
        (" read this message carefully.", "Thanks for taking the time to", " read this message carefully."),
        ("was rescheduled due to unforeseen circumstances.", "the meeting ", "was rescheduled due to unforeseen circumstances."),
        ("\"getting back to me.\"", "Thanks for", " getting back to me."),
        ("Thanks for getting back to me.", "Thanks for", " getting back to me."),
        ("Continuation: the next step.", "First we", " the next step."),
        ("", "abc", nil), ("   \n   ", "abc", nil), ("...", "abc", nil),
        ("ately available.", "unfortun", "ately available."),
        (" first line\nsecond dropped", "He said", " first line"),
        (", which is fine.", "the result", ", which is fine."),
        ("Thanks for taking the time to Please let me know your availability.",
         "Thanks for taking the time to  Please let me",
         " know your availability."),

        // The two corruptions the leading-space rule used to cause, both from
        // overriding the model with a spell-checker verdict.
        //
        // "avail" is a finished word to the checker and also a prefix of longer
        // ones, so a space was forced into the middle of one: the model's "ble"
        // was delivered as " ble", and the field read "avail ble".
        ("ble to answer any questions.", "I am avail", "ble to answer any questions."),
        ("ons, please say so.", "If you have any quest", "ons, please say so."),
        // "resched" is not a word, so the space the model *did* emit was taken
        // away and the field read "reschedthe meeting".
        (" the meeting for Tuesday.", "Let me know if we should resched",
         " the meeting for Tuesday."),
        // A word that is genuinely finished still gets its space, because the
        // model puts one there.
        (" at three if that suits.", "The meeting is tomorrow", " at three if that suits."),

        // The fallback: each of these rewrites the head of the string, taking
        // the model's answer with it, so the caller's verdict is all there is.
        // "we" is a finished word, so the space comes back.
        ("Answer: the next step.", "First we", " the next step."),
        ("\"the next step.\"", "First we", " the next step."),
    ]
    var fail = 0
    for c in cases {
        let needs = WordBoundary.caretEndsCompleteWord(c.before)
        let got = CompletionSanitizer.sanitize(c.raw, before: c.before, needsLeadingSpace: needs)
        if got != c.expect {
            fail += 1
            print("FAIL before=\(c.before.debugDescription)\n  want \(String(describing: c.expect))\n  got  \(String(describing: got))")
        }
    }
    print(fail == 0 ? "All \(cases.count) sanitize cases passed (post-extraction)." : "\(fail) FAILED")
    exit(fail == 0 ? 0 : 1)
}
run()
