import Foundation

func run() {
    var fail = 0
    func check(_ label: String, _ condition: Bool) {
        guard !condition else { return }
        fail += 1
        print("FAIL \(label)")
    }

    // The reply case. `after` holds the quoted original, which is what decides
    // the suggestion and what the prompt used to throw away entirely.
    let quoted = """


        On 14 September 2026, Priya Raman wrote:
        > Could you confirm whether the Tuesday workshop is still going ahead,
        > and how many seats we should reserve for the design team?
        """
    let reply = CompletionRequest(
        before: "Hi Priya, thanks for checking — the workshop",
        after: quoted,
        appName: "Mail",
        needsLeadingSpace: true
    )
    let prompt = CompletionPrompt.text(for: reply)

    check("quoted message reaches the prompt", prompt.contains("how many seats we should reserve"))
    check("quoted message is labelled", prompt.contains("[Text after the cursor:"))
    check("quoted block is folded onto one line",
          !prompt.components(separatedBy: "[Text after the cursor:")[1]
              .components(separatedBy: "]")[0].contains("\n"))
    check("the user's own text stays last so the KV prefix is reusable",
          prompt.hasSuffix("Hi Priya, thanks for checking — the workshop"))
    check("app name is framed", prompt.contains("[Writing in Mail]"))

    // Who is being written to, read out of the quoted original. The block sits
    // last of the context blocks so the given name is the nearest name to the
    // caret; see `Correspondent` for why that is the whole point.
    check("the correspondent reaches the prompt", prompt.contains("[Writing to: Priya Raman"))
    check("the correspondent block is the last before the user's own text",
          prompt.range(of: "[Writing to:")!.lowerBound
              > prompt.range(of: "[Text after the cursor:")!.lowerBound)

    // The real shape, and the one that was wrong: every mention of the
    // recipient in Apple Mail is surname-first, so the nearest capitalised word
    // to a half-typed "Hi C" was "Hodge".
    let surnameFirst = CompletionRequest(
        before: "Hi C",
        after: "\n\nOn Sep 15, 2026, at 9:53 AM, Hodge, Christine "
            + "<Christine.Hodge@contractor.oakland.k12.mi.us> wrote:\n\nHello,\n\n"
            + "This is Christine from Oakland Schools, Help Me Grow.",
        appName: "Mail",
        needsLeadingSpace: false
    )
    let greeting = CompletionPrompt.text(for: surnameFirst)
    check("the given name is named as such",
          greeting.contains("[Writing to: Christine Hodge, first name Christine]"))
    check("the given name is the last name the model reads before the caret",
          greeting.range(of: "Christine]")!.lowerBound > greeting.range(of: "Hodge, Christine <")!.lowerBound)

    // Derived from context that holds still, not from `before`, or typing the
    // greeting would re-decode the whole prompt on every keystroke.
    let typed = CompletionRequest(
        before: "Hi Ch",
        after: surnameFirst.after,
        appName: "Mail",
        needsLeadingSpace: false
    )
    check("the correspondent block does not break prefix reuse",
          CompletionPrompt.text(for: typed).commonPrefix(with: greeting).count >= greeting.count - 48)

    // Nobody to name is not a block.
    let anonymous = CompletionRequest(
        before: "Thanks for", after: "the quick turnaround on all of this.", needsLeadingSpace: true
    )
    check("no correspondent adds no block",
          !CompletionPrompt.text(for: anonymous).contains("[Writing to:"))

    // Everything before `before` must be identical between two keystrokes, or
    // prefix reuse collapses and every pass re-decodes the whole prompt.
    let next = CompletionRequest(
        before: "Hi Priya, thanks for checking — the workshop is",
        after: quoted,
        appName: "Mail",
        needsLeadingSpace: false
    )
    let shared = CompletionPrompt.text(for: next).commonPrefix(with: prompt)
    check("prompt prefix is shared across keystrokes", shared.count >= prompt.count - 48)

    // A fragment after the caret is not context worth a block of its own.
    let midLine = CompletionRequest(before: "the result", after: ".", needsLeadingSpace: false)
    check("a stray character adds no block",
          !CompletionPrompt.text(for: midLine).contains("[Text after the cursor:"))

    let empty = CompletionRequest(before: "the result", after: "", needsLeadingSpace: false)
    check("empty after adds no block",
          !CompletionPrompt.text(for: empty).contains("[Text after the cursor:"))

    // Bounded, so a long quoted thread cannot crowd out the sentence in hand.
    let long = CompletionRequest(
        before: "Thanks",
        after: String(repeating: "word ", count: 500),
        needsLeadingSpace: true
    )
    check("after is bounded", CompletionPrompt.text(for: long).count < 900)

    // OCR and clipboard are folded too: a raw multi-line screen dump invites the
    // model to reproduce the dump instead of the sentence.
    let screen = CompletionRequest(
        before: "Thanks for",
        after: "",
        ocrText: "Inbox\nPriya Raman\nWorkshop seats",
        clipboard: "Tuesday 22nd\nRoom 4",
        needsLeadingSpace: true
    )
    let screenPrompt = CompletionPrompt.text(for: screen)
    check("ocr block is one line", screenPrompt.contains("[On screen: Inbox Priya Raman Workshop seats]"))
    check("clipboard block is one line", screenPrompt.contains("[Clipboard: Tuesday 22nd Room 4]"))

    // Recent phrasing. Every other context source had a case here; this one did
    // not, which is how it spent the app's life being read, stored, snapshotted
    // and then dropped on the floor at the last step.
    let voiced = CompletionRequest(
        before: "Hi Priya, thanks for checking — the workshop",
        after: "",
        appName: "Mail",
        recentPhrasing: [
            "Happy to run through it on Thursday if that suits — I'll bring the seating plan.",
            "Quick one: are we still fixed on the Tuesday slot, or is there room to move?",
            "Thanks for the nudge. I'll have the numbers over to you before the end of play.",
            "a fourth line that must not appear",
        ],
        needsLeadingSpace: true
    )
    let voicedPrompt = CompletionPrompt.text(for: voiced)
    check("recent phrasing reaches the prompt", voicedPrompt.contains("I'll bring the seating plan"))
    check("recent phrasing is labelled", voicedPrompt.contains("[How this person writes:"))
    check("recent phrasing is bounded to three lines",
          !voicedPrompt.contains("a fourth line that must not appear"))
    check("the user's own text still comes last",
          voicedPrompt.hasSuffix("Hi Priya, thanks for checking — the workshop"))

    // Long snippets are folded and clipped like every other block, or one stored
    // paragraph crowds out the sentence in hand.
    let wordy = CompletionRequest(
        before: "Thanks",
        after: "",
        recentPhrasing: Array(repeating: String(repeating: "padding ", count: 200), count: 3),
        needsLeadingSpace: true
    )
    check("recent phrasing is bounded per line", CompletionPrompt.text(for: wordy).count < 500)

    // Fragments are not a voice.
    let scrap = CompletionRequest(
        before: "Thanks", after: "", recentPhrasing: ["ok", "sure"], needsLeadingSpace: true
    )
    check("a scrap of phrasing adds no block",
          !CompletionPrompt.text(for: scrap).contains("[How this person writes:"))

    let unvoiced = CompletionRequest(before: "Thanks", after: "", needsLeadingSpace: true)
    check("no phrasing adds no block",
          !CompletionPrompt.text(for: unvoiced).contains("[How this person writes:"))

    // The block holds still while the user types, so the cached prefix survives.
    let voicedNext = CompletionRequest(
        before: "Hi Priya, thanks for checking — the workshop is",
        after: "",
        appName: "Mail",
        recentPhrasing: voiced.recentPhrasing,
        needsLeadingSpace: false
    )
    let voicedShared = CompletionPrompt.text(for: voicedNext).commonPrefix(with: voicedPrompt)
    check("phrasing does not break prefix reuse",
          voicedShared.count >= voicedPrompt.count - 48)

    print(fail == 0 ? "All prompt cases passed." : "\(fail) FAILED")
    exit(fail == 0 ? 0 : 1)
}
run()
