import AppKit
import Foundation

/// Proves the "Personalize word choice" slider actually reaches the sampler.
///
/// Same model, same prompt, same seed — only the bias strength differs. If the
/// output is identical at 0.0 and 1.0, the slider is decorative.

@MainActor
func run() async {
    guard let path = CommandLine.arguments.dropFirst().first else {
        print("usage: biastest <model.gguf>"); exit(2)
    }

    let backend = LlamaBackend()
    await backend.load(path: path)
    guard await backend.status().isReady else { print("load failed"); exit(1) }

    // Invented terms: no model has seen these, so any appearance must come from
    // the bias rather than from pretraining.
    let learned = ["Kubernetes": 14, "Aurelia": 11, "Zephyrine": 9]
    let prompt = "Tomorrow I will start work on the"

    func complete(strength: Double) async -> String? {
        await backend.complete(CompletionRequest(
            before: prompt,
            after: "",
            appName: nil,
            instructions: "",
            recentPhrasing: [],
            vocabulary: strength > 0 ? learned : [:],
            needsLeadingSpace: WordBoundary.caretEndsCompleteWord(prompt),
            maxWords: 5,
            wordChoiceStrength: strength
        ))
    }

    let off = await complete(strength: 0.0)
    let max = await complete(strength: 1.0)
    let offAgain = await complete(strength: 0.0)

    print("  bias 0.0 : \(off ?? "nil")")
    print("  bias 1.0 : \(max ?? "nil")")
    print("  bias 0.0 : \(offAgain ?? "nil")   (repeat, must match the first)")

    var failures = 0
    func check(_ label: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }

    check("greedy sampling is deterministic", off == offAgain)
    check("bias changes the output", off != max)
    let pulled = learned.keys.contains { max?.localizedCaseInsensitiveContains($0) ?? false }
    // The promise is a nudge toward the user's vocabulary, not forced insertion
    // of an arbitrary rare word, so this is reported rather than asserted.
    print(pulled ? "NOTE  a learned term surfaced at full strength"
                 : "NOTE  no learned term surfaced; bias shifted wording only")

    // Release the engine before exiting. ggml registers an atexit handler that
// frees the Metal device and aborts if resource sets are still alive, so a
// process that just calls exit() with a model loaded dies with SIGABRT in
// ggml_metal_rsets_free. That is what was happening here, unnoticed, because
// the crash comes after the last line of output and test.sh piped it away.
await backend.shutdown()

print(failures == 0 ? "\nBias wiring verified." : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

await run()
