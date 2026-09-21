import Foundation

/// The counters shown in Settings > Statistics, which now outlive the session.
/// Persistence is the whole point, so the round trip is what matters most here.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// A fresh tally.
var stats = Statistics()
check("starts at nothing", stats.accepted == 0 && stats.words == 0)

stats.record(words: 3)
stats.record(words: 2)
check("counts each acceptance", stats.accepted == 2)
check("counts the words they inserted", stats.words == 5)

// An acceptance that inserted nothing still happened.
stats.record(words: 0)
check("a wordless acceptance still counts", stats.accepted == 3 && stats.words == 5)

// A caller bug must not corrupt a total that now survives quitting.
stats.record(words: -5)
check("a negative count cannot eat the total", stats.words == 5)

// Reset moves the start date, or the figures would claim to cover a period
// they no longer do.
let before = stats.since
let later = Date(timeIntervalSinceNow: 60)
stats.reset(now: later)
check("reset zeroes the counts", stats.accepted == 0 && stats.words == 0)
check("reset moves the start date", stats.since == later && stats.since != before)

// MARK: Round trip

let suite = "ft.statistics.tests.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suite) else {
    print("FAIL could not make a test defaults suite"); exit(1)
}

let empty = Statistics.load(from: defaults)
check("an empty store starts at nothing", empty.accepted == 0 && empty.words == 0)

var saved = Statistics()
saved.record(words: 7)
saved.record(words: 4)
saved.save(to: defaults)
let loaded = Statistics.load(from: defaults)
check("counts survive the round trip", loaded.accepted == 2 && loaded.words == 11)
// Dates go through JSON as a number, so equality here is the real check that
// the tally still knows what period it covers.
check("the start date survives too",
      abs(loaded.since.timeIntervalSince(saved.since)) < 0.001)

// Garbage in the slot must not take the pane down with it.
defaults.set(Data([0x00, 0x01, 0x02]), forKey: "ft.statistics")
let recovered = Statistics.load(from: defaults)
check("unreadable data starts again from zero", recovered.accepted == 0 && recovered.words == 0)

defaults.removePersistentDomain(forName: suite)

print(failures == 0 ? "\nAll statistics cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
