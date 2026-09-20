import Foundation

/// The latency window. Pure arithmetic, so it is pinned here rather than
/// eyeballed in the settings row — a percentile that quietly reports the wrong
/// number is worse than none, because it would be trusted.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// Nothing measured yet.
var empty = LatencyStats()
check("empty has no median", empty.median == nil)
check("empty says so", empty.summary == "Not measured yet")
check("empty counts nothing", empty.count == 0 && empty.isEmpty)

// One sample is its own every percentile.
empty.record(162)
check("one sample is the median", empty.median == 162)
check("one sample is the 90th", empty.ninetieth == 162)
check("one sample is the slowest", empty.slowest == 162)

// Nearest-rank over a known set: 1...10 has median 5 and 90th 9.
var known = LatencyStats()
for value in 1...10 { known.record(value) }
check("median of 1...10 is 5", known.median == 5)
check("90th of 1...10 is 9", known.ninetieth == 9)
check("slowest of 1...10 is 10", known.slowest == 10)

// Order must not matter.
var shuffled = LatencyStats()
for value in [7, 2, 9, 4, 1, 10, 3, 8, 5, 6] { shuffled.record(value) }
check("percentiles ignore arrival order", shuffled.median == known.median
      && shuffled.ninetieth == known.ninetieth)

// The window slides: the oldest readings have to leave, or a fast start hides
// a slow now.
var sliding = LatencyStats()
for _ in 0..<LatencyStats.windowSize { sliding.record(50) }
check("window fills to its size", sliding.count == LatencyStats.windowSize)
for _ in 0..<LatencyStats.windowSize { sliding.record(500) }
check("window never grows past its size", sliding.count == LatencyStats.windowSize)
check("the old readings are gone", sliding.median == 500)

// Half replaced. The median sits on the boundary and nearest-rank takes the
// lower side of it, so it is still the older reading — the 90th is what has
// moved. That is the right way round for a settings row: the typical number
// should not jump the moment conditions change, and the slow number should.
var half = LatencyStats()
for _ in 0..<LatencyStats.windowSize { half.record(50) }
for _ in 0..<(LatencyStats.windowSize / 2) { half.record(500) }
check("a half-turned window still holds both halves", half.count == LatencyStats.windowSize)
check("its median is the older half", half.median == 50)
check("its 90th has moved to the newer half", half.ninetieth == 500)
check("its slowest is the newer half", half.slowest == 500)

// Readings that cannot be real say nothing about the engine.
var guarded = LatencyStats()
guarded.record(-1)
guarded.record(120_000)
check("a negative reading is refused", guarded.isEmpty)
guarded.record(0)
check("zero is a legitimate reading", guarded.count == 1)

// Reset, for a model switch: the previous model's numbers are not this one's.
var resettable = LatencyStats()
for value in 1...10 { resettable.record(value) }
resettable.reset()
check("reset clears the window", resettable.isEmpty && resettable.median == nil)

// The summary is one line and carries both numbers.
var summarised = LatencyStats()
for value in [100, 200, 300] { summarised.record(value) }
check("summary carries typical and slow",
      summarised.summary.contains("\(summarised.median!)")
      && summarised.summary.contains("\(summarised.ninetieth!)"))
check("summary is one line", !summarised.summary.contains("\n"))

print(failures == 0 ? "\nAll latency cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
