import AppKit
import Foundation

/// Proves the KV-cache prefix reuse the engine's affordability rests on.
///
/// Consecutive keystrokes share almost all of their prompt, so only the
/// diverging suffix should ever be decoded. That claim was visible only in a log
/// line, and it was quietly false for the *second* request of every session:
/// BOS was added when the cache was empty and omitted thereafter, so request two
/// compared a prompt with no BOS against a cached array that began with one,
/// found nothing in common, and re-decoded the lot — after which every prompt
/// ran without the BOS the model was trained to expect.

@MainActor
func run() async {
    guard let path = CommandLine.arguments.dropFirst().first else {
        print("usage: cachetest <model.gguf>"); exit(2)
    }

    let backend = LlamaBackend()
    await backend.load(path: path)
    guard await backend.status().isReady else { print("load failed"); exit(1) }
    // The app warms the model before the first keystroke, so the test has to as
    // well: warm-up leaves tokens in the cache that the first request must clear.
    await backend.warmUp()

    // One sentence typed a word at a time, which is what the coordinator
    // actually sends: `before` grows, every other block is unchanged.
    let stem = "Thanks for taking the time to look at the proposal. I think the plan"
    let typed = [stem, stem + " is", stem + " is looking", stem + " is looking rather"]

    var rows: [(step: Int, shared: Int, total: Int, bos: Bool)] = []
    var wantsBOS = false
    var consistent = true

    for (index, before) in typed.enumerated() {
        _ = await backend.complete(CompletionRequest(
            before: before,
            after: "",
            appName: "Mail",
            instructions: "",
            recentPhrasing: [],
            vocabulary: [:],
            needsLeadingSpace: WordBoundary.caretEndsCompleteWord(before),
            maxWords: 4,
            wordChoiceStrength: 0
        ))
        let d = await backend.diagnostics()
        wantsBOS = d.wantsBOS
        rows.append((index + 1, d.shared, d.promptTokens, d.beganWithBOS))
        consistent = consistent && d.cacheIsConsistent
        print(String(
            format: "  request %d  reuse %3d/%-3d = %3.0f%%   bos=%@",
            index + 1, d.shared, d.promptTokens, d.reuseFraction * 100,
            d.beganWithBOS ? "yes" : "no "
        ))
    }
    print("  model asks for a BOS: \(wantsBOS ? "yes" : "no")")

    // The record of what the cache holds has to match what it actually holds.
    // It did not: the generated token was appended to that record *before* the
    // decode that put it there, so both of the loop's early exits — a failed
    // decode, and the degenerate-repeat break that is the loop's whole reason
    // for existing — left the record one ahead of the truth. Loop-bait below,
    // because the cheapest way to fire that break is to make the model loop.
    // These four were chosen by measurement, not by ear: across 66 generations
    // on each of two models, they are the ones that reliably reach the break —
    // which fired 9 times in 66 on Gemma 3 1B and 3 in 66 on Qwen 3 1.7B, and
    // drifted the record on every single one of them.
    let bait = [
        "The answer to every one of them was yes, yes, yes, yes, yes",
        "buy buy buy buy buy buy buy buy",
        "blah blah blah blah blah blah",
        "the the the the the the the the",
    ]
    var baitTripped = 0
    for before in bait {
        _ = await backend.complete(CompletionRequest(
            before: before, after: "", appName: nil, instructions: "",
            recentPhrasing: [], vocabulary: [:],
            needsLeadingSpace: WordBoundary.caretEndsCompleteWord(before),
            maxWords: 12, wordChoiceStrength: 0
        ))
        let d = await backend.diagnostics()
        if !d.cacheIsConsistent {
            baitTripped += 1
            print("      drift: tracked \(d.trackedTokens) vs resident \(d.residentTokens) — \"\(before.suffix(28))\"")
        }
        consistent = consistent && d.cacheIsConsistent
    }

    // A prompt that overflows the 2,048-token window. Two things used to go
    // wrong here and only one of them was on the list.
    //
    // The crash first: the diverging suffix was handed to `llama_decode` in one
    // piece, and a context built with `n_batch` 512 does not return an error
    // when given more — it fails `GGML_ASSERT(n_tokens_all <= cparams.n_batch)`
    // and aborts the process. Reaching the checks below at all is the assertion.
    //
    // Then the reuse: trimming to an exact fit slid the window by a token per
    // keystroke, which moved the start of the prompt and left nothing for the
    // cache to match, so every pass re-decoded some two thousand tokens.
    // Instructions are inflated because they are the one context source with no
    // ceiling of its own.
    let overflowing = String(repeating: "Write plainly and keep every sentence short. ", count: 400)
    var overflowRows: [(shared: Int, total: Int)] = []
    for before in typed {
        _ = await backend.complete(CompletionRequest(
            before: before, after: "", appName: "Mail", instructions: overflowing,
            recentPhrasing: [], vocabulary: [:],
            needsLeadingSpace: WordBoundary.caretEndsCompleteWord(before),
            maxWords: 4, wordChoiceStrength: 0
        ))
        let d = await backend.diagnostics()
        overflowRows.append((d.shared, d.promptTokens))
        consistent = consistent && d.cacheIsConsistent
    }
    let overflowed = overflowRows.contains { $0.total > Int(512) }
    let overflowLater = overflowRows.dropFirst()

    var failures = 0
    func check(_ label: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }

    check("the cache record matches what the cache holds", consistent)

    check("an over-long prompt is decoded rather than aborting on", overflowed)
    check("an over-long prompt still reuses its prefix",
          overflowLater.allSatisfy { Double($0.shared) / Double($0.total) >= 0.9 })
    for (index, row) in overflowLater.enumerated() where Double(row.shared) / Double(row.total) < 0.9 {
        print("      overflow request \(index + 2) reused \(row.shared)/\(row.total)")
    }
    if baitTripped > 0 { print("      \(baitTripped) of \(bait.count) loop-bait prompts drifted") }

    // Request 1 starts from an empty cache and must decode everything; that is
    // correct, not a regression, so it is not asserted.
    let later = rows.dropFirst()
    let worst = later.map(\.self).min { $0.shared * $1.total < $1.shared * $0.total }

    check("every request after the first reuses most of its prompt",
          later.allSatisfy { Double($0.shared) / Double($0.total) >= 0.8 })
    if let worst, Double(worst.shared) / Double(worst.total) < 0.8 {
        print("      worst: request \(worst.step) reused \(worst.shared)/\(worst.total)")
    }

    // The regression had a signature: request 2 specifically, and only it.
    check("request 2 does not re-decode from scratch", rows[1].shared > 0)

    // A prompt is the whole prompt every time, never a delta, so a model that
    // asks for a BOS must get one on every request — not only the first.
    if wantsBOS {
        check("every prompt carries the model's BOS", rows.allSatisfy(\.bos))
    } else {
        print("NOTE  this model sets add_bos false, so BOS presence is not asserted")
        print("      the reuse check above is what catches the regression here")
    }

    // ggml asserts in its own atexit handler if the Metal resource sets are
    // still alive, so the model comes down before the process does.
    await backend.shutdown()

    print(failures == 0 ? "\nKV-cache reuse verified." : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

await run()
