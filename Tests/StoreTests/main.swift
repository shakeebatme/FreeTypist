import Foundation

/// Verifies the promises made about the personalization store: text round-trips,
/// nothing readable is left on disk, the term index cannot be reversed, and
/// delete really deletes.

@MainActor
enum Harness {
    static var failures = 0

    static func check(_ label: String, _ condition: Bool) {
        print("\(condition ? "PASS" : "FAIL") \(label)")
        if !condition { failures += 1 }
    }
}

@MainActor func check(_ label: String, _ condition: Bool) { Harness.check(label, condition) }

@MainActor
func run() async {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ft-store-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let secret = "Shakeeb met Aurelia about the Zephyrine migration on Tuesday"
    let rareTerm = "Zephyrine"

    let store = PersonalizationStore(directoryOverride: temp)
    await store.record(text: secret, app: "com.apple.mail")
    await store.record(text: "Another note about the \(rareTerm) rollout plan", app: "com.apple.mail")

    // 1. Round trip
    let snapshot = await store.snapshot(app: "com.apple.mail")
    check("recorded text reads back", snapshot.recentPhrasing.contains { $0.contains(rareTerm) })
    check("vocabulary learned the rare term", snapshot.vocabulary.keys.contains(rareTerm))
    check("common words filtered out", !snapshot.vocabulary.keys.contains("about"))

    // 2. Our own suggestions are writing, but not vocabulary.
    //
    // The snippet is what the user sent and they accepted every word of it, so
    // it stays. The vocabulary drives a logit bias with counts that never decay,
    // so a word we put there must not tilt the model toward producing it again.
    let ourWord = "Thessaly"
    let theirWord = "Bracknell"
    await store.record(
        text: "Notes from \(theirWord) about the \(ourWord) handover",
        app: "com.apple.notes",
        ourOwnText: "the \(ourWord) handover"
    )
    let notes = await store.snapshot(app: "com.apple.notes")
    check("our own suggestion stays in the phrasing",
          notes.recentPhrasing.contains { $0.contains(ourWord) })
    check("our own suggestion is not learned as vocabulary",
          !notes.vocabulary.keys.contains(ourWord))
    check("the user's own word beside it still is",
          notes.vocabulary.keys.contains(theirWord))

    // Case folding: a term is stored under the HMAC of its lowercase form, so
    // the excluded side has to fold too or the subtraction misses.
    await store.record(
        text: "Rolling out \(ourWord.lowercased()) everywhere next quarter",
        app: "com.apple.notes",
        ourOwnText: "out \(ourWord) everywhere"
    )
    let folded = await store.snapshot(app: "com.apple.notes")
    check("exclusion is case-insensitive",
          !folded.vocabulary.keys.contains { $0.lowercased() == ourWord.lowercased() })

    // 3. Per-app scoping
    let other = await store.snapshot(app: "com.other.app")
    check("other app sees no phrasing", other.recentPhrasing.isEmpty)

    let stats = await store.stats()
    check("stats report content", stats.snippets == 4 && stats.terms > 0)

    // 4. Nothing readable on disk — the whole point of the encryption.
    var onDisk = Data()
    for suffix in ["", "-wal", "-shm"] {
        let path = temp.appendingPathComponent("personalization.sqlite" + suffix).path
        if let data = FileManager.default.contents(atPath: path) { onDisk.append(data) }
    }
    check("database file is non-empty", !onDisk.isEmpty)
    let raw = String(decoding: onDisk, as: UTF8.self)
    check("plaintext sentence absent from disk", !raw.contains("Zephyrine migration"))
    check("rare term absent from disk", !raw.contains(rareTerm))
    check("term index is not the plaintext term", !raw.lowercased().contains(rareTerm.lowercased()))

    // 4. Delete really deletes
    await store.deleteEverything()
    var anyLeft = false
    for suffix in ["", "-wal", "-shm"] {
        if FileManager.default.fileExists(
            atPath: temp.appendingPathComponent("personalization.sqlite" + suffix).path
        ) { anyLeft = true }
    }
    check("no database files remain after delete", !anyLeft)

    let reopened = PersonalizationStore(directoryOverride: temp)
    let after = await reopened.snapshot(app: "com.apple.mail")
    check("nothing readable after delete", after.recentPhrasing.isEmpty && after.vocabulary.isEmpty)

    print(Harness.failures == 0 ? "\nAll store cases passed." : "\n\(Harness.failures) FAILED")
    exit(Harness.failures == 0 ? 0 : 1)
}

await run()
