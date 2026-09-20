import AppKit
import Foundation

/// Token healing: that a completion offered mid-word actually finishes the word.
///
/// A tokenizer splits " available" into one token and " avail" into another, so
/// a prompt stopping mid-word stops on a token that says the word is finished.
/// Conditioned on that, the model writes what follows the word "avail" — the
/// measured answers before healing were "availble", "questons", "documnet",
/// "repoort" and "thro'".
///
/// The invariant asserted here is the one that was being broken: *if* the model
/// continues the word rather than starting a new one, the join has to be a real
/// word. Whether it chooses to continue at all is its business — "tomorrow" is
/// finished, and " at three" is a fine answer to it.

let fragments = [
    ("I will investigate this thoroughly and repo", "repo"),
    ("Let me know if we should resched", "resched"),
    ("I have attach", "attach"),
    ("Just writing to conf", "conf"),
    ("Please see the attached docum", "docum"),
    ("I am avail", "avail"),
    ("I am writing regard", "regard"),
    ("Apolog", "Apolog"),
    ("I went thro", "thro"),
    ("If you have any quest", "quest"),
]

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

@MainActor
func run() async {
    guard let path = CommandLine.arguments.dropFirst().first else {
        print("usage: healing <model.gguf>")
        exit(2)
    }
    let backend = LlamaBackend()
    await backend.load(path: path)
    guard await backend.status().isReady else {
        print("  load failed")
        exit(1)
    }
    await backend.warmUp()

    var extended = 0
    for (before, fragment) in fragments {
        let request = CompletionRequest(
            before: before,
            after: "",
            appName: "Mail",
            instructions: "",
            needsLeadingSpace: WordBoundary.caretEndsCompleteWord(before),
            maxWords: 6
        )
        guard let text = await backend.complete(request), !text.isEmpty else {
            check("\(fragment): produced something", false)
            continue
        }

        // A completion opening with a space starts a new word and says nothing
        // about this one.
        guard text.first?.isWhitespace != true else {
            print("SKIP \(fragment): started a new word (\(text.debugDescription))")
            continue
        }
        extended += 1

        let tail = text.prefix { !$0.isWhitespace && !$0.isPunctuation }
        let joined = fragment + tail
        let misspelt = NSSpellChecker.shared
            .checkSpelling(of: joined, startingAt: 0).location != NSNotFound
        check("\(fragment) + \(tail) = \(joined)", !misspelt)
    }

    // Healing that finds no candidate would silently drop the word from the
    // prompt, which is how "resched" once became " send a letter". One token
    // always extends itself, so this can only fire if the index and the
    // tokenizer have come apart.
    let diagnostics = await backend.diagnostics()
    check("healing never failed to find a candidate", diagnostics.healingFallbacks == 0)
    check("most fragments were actually extended", extended >= fragments.count - 2)

    await backend.unload()
    print(failures == 0 ? "\nToken healing verified." : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

await run()
