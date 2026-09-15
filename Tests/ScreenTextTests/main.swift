import Foundation
import CoreGraphics

/// Quartz coordinates throughout: y grows downward, so a line with a larger
/// `y` sits lower on the screen.
func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 300, height: CGFloat = 16) -> ScreenLine {
    ScreenLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
}

func run() {
    var fail = 0
    func check(_ label: String, _ condition: Bool) {
        guard !condition else { return }
        fail += 1
        print("FAIL \(label)")
    }

    // The case the whole screen scan exists for: a reference window on the left,
    // the field being typed in on the right. The reference text is in neither
    // the focused field nor the focused window, and it is the only thing on
    // screen worth carrying.
    let reference = [
        line("The Tuesday workshop runs from ten until half past three", x: 40, y: 200),
        line("and there are twelve seats reserved for the design team.", x: 40, y: 220),
        line("Lunch is provided; the room is on the fourth floor.", x: 40, y: 240),
    ]
    let field = CGRect(x: 800, y: 180, width: 400, height: 120)
    // Deliberately absent from `known` below, so only the geometry can drop it:
    // this is the half-typed word the field would otherwise feed back to itself.
    let inField = [
        line("Sent from a window that happens to hold the caret", x: 810, y: 190),
    ]
    let chrome = [
        line("Inbox", x: 0, y: 40, width: 60),
        line("Drafts", x: 0, y: 60, width: 60),
        line("File Edit", x: 0, y: 80, width: 70),
    ]

    let condensed = ScreenText.condense(
        reference + inField + chrome,
        excluding: field,
        known: ScreenText.fold("Hi Priya, thanks for checking — the workshop")
    )

    check("text from an unfocused window is carried",
          condensed.contains("twelve seats reserved for the design team"))
    check("the whole reference paragraph survives as one block",
          condensed.contains("fourth floor"))
    check("text inside the focused field is dropped on geometry alone",
          !condensed.contains("happens to hold the caret"))
    check("short sidebar chrome is dropped", !condensed.lowercased().contains("drafts"))

    // Two windows side by side must not be welded into one interleaved block:
    // the left column's second line must follow its first, not the right
    // column's.
    let left = [
        line("The specification says the retry budget is three attempts", x: 40, y: 400, width: 380),
        line("with exponential backoff starting at two hundred milliseconds.", x: 40, y: 420, width: 380),
    ]
    let right = [
        line("Unrelated notes about the quarterly planning meeting", x: 700, y: 400, width: 380),
        line("and who is expected to attend it on Thursday morning.", x: 700, y: 420, width: 380),
    ]
    let columns = ScreenText.condense(left + right, excluding: nil, known: "")
    let lines = columns.split(separator: "\n").map(String.init)
    check("side-by-side windows stay separate blocks", lines.count == 2)
    check("the left column stays contiguous",
          lines.contains { $0.contains("three attempts") && $0.contains("exponential backoff") })
    check("the right column stays contiguous",
          lines.contains { $0.contains("quarterly planning") && $0.contains("Thursday morning") })

    // Ranking: the budget must go to the paragraph, not to whatever happens to
    // sit nearest the top left, which is what plain reading order gave.
    // A real competing block, not chrome: contiguous, well over the block
    // minimum, and first in reading order. Reading order alone would spend the
    // whole budget on it.
    let noise = (0..<6).map { index in
        line("Sidebar entry \(index) for some navigation tree", x: 0, y: 40 + CGFloat(index) * 20, width: 220)
    }
    let paragraph = (0..<8).map { index in
        line("Body line \(index) of the document the user is actually reading here",
             x: 500, y: 100 + CGFloat(index) * 20, width: 600)
    }
    let ranked = ScreenText.condense(noise + paragraph, excluding: nil, known: "")
    check("the longest block leads, not the one first in reading order",
          ranked.hasPrefix("Body line 0"))
    check("the smaller block still follows when there is budget for it",
          ranked.contains("navigation tree"))
    check("ranked output respects the character limit",
          ranked.count <= ScreenText.characterLimit)

    // Already-known text is subtracted even when it is not geometrically inside
    // the field — a web editor reports no usable field rect at all.
    let known = ScreenText.fold("The Tuesday workshop runs from ten until half past three")
    let deduped = ScreenText.condense(reference, excluding: nil, known: known)
    check("text already in the prompt is not repeated",
          !deduped.contains("runs from ten until half past three"))
    check("the rest of the block still comes through",
          deduped.contains("twelve seats"))

    // Case is a context source of its own: a lowercased screen has no proper
    // nouns on it, and the To: field exists to supply exactly one.
    let cased = ScreenText.condense(
        [line("To: Hodge, Christine", x: 40, y: 600),
         line("Subject: Re: ASQ Developmental Screening", x: 40, y: 620)],
        excluding: nil,
        known: ""
    )
    check("recognised text keeps its capitalisation", cased.contains("Hodge, Christine"))

    // Mirrored displays hand back the same strings twice.
    let mirrored = ScreenText.condense(reference + reference, excluding: nil, known: "")
    check("duplicate lines are carried once",
          mirrored.components(separatedBy: "twelve seats").count == 2)

    // A dominant window must not starve the reference pane. This is the shape
    // the live screen produced: a terminal filling most of the screen against a
    // much smaller pane of the text actually being referred to.
    let dominant = (0..<30).map { index in
        line("Terminal output line \(index) with a good deal of text on it indeed",
             x: 0, y: 100 + CGFloat(index) * 20, width: 900)
    }
    let pane = (0..<4).map { index in
        line("Reference pane line \(index) about the workshop seating",
             x: 1000, y: 100 + CGFloat(index) * 20, width: 400)
    }
    let shared = ScreenText.condense(dominant + pane, excluding: nil, known: "")
    check("the dominant block does not take the whole budget",
          shared.contains("Reference pane line 0"))
    check("the dominant block is still represented",
          shared.contains("Terminal output line 0"))
    check("sharing respects the character limit", shared.count <= ScreenText.characterLimit)

    // With only one block there is nothing to share with, so it gets the lot.
    let alone = ScreenText.condense(dominant, excluding: nil, known: "")
    check("a lone block still gets the full budget",
          alone.count > ScreenText.characterLimit / 2)

    if fail == 0 {
        print("PASS screen text")
    } else {
        print("\(fail) failing")
        exit(1)
    }
}

run()
