import AppKit
@MainActor func run() {
    let cases: [(raw: String, before: String, expect: String?)] = [
        ("read this message carefully.", "Thanks for taking the time to", " read this message carefully."),
        ("was rescheduled due to unforeseen circumstances.", "the meeting ", "was rescheduled due to unforeseen circumstances."),
        ("\"getting back to me.\"", "Thanks for", " getting back to me."),
        ("Thanks for getting back to me.", "Thanks for", " getting back to me."),
        ("Continuation: the next step.", "First we", " the next step."),
        ("", "abc", nil), ("   \n   ", "abc", nil), ("...", "abc", nil),
        ("ately available.", "unfortun", "ately available."),
        ("first line\nsecond dropped", "He said", " first line"),
        (", which is fine.", "the result", ", which is fine."),
        ("Thanks for taking the time to Please let me know your availability.",
         "Thanks for taking the time to  Please let me",
         " know your availability."),
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
