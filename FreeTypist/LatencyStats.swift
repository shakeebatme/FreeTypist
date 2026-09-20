import Foundation

/// How long recent suggestions took to generate.
///
/// The claim this app rests on is that a suggestion arrives before the user has
/// finished thinking about the next word, and until now nothing measured it:
/// `LlamaBackend` logged a line per request and nothing read the lines back. A
/// regression was therefore only visible to someone watching the log with a
/// stopwatch, which in practice meant building a throwaway harness every time
/// the question came up.
///
/// Recent rather than lifetime, deliberately. What matters is what the machine
/// is doing now — a different model, a busy GPU, a laptop on battery — and a
/// mean over the whole session hides exactly that. The window is small enough
/// to follow a change within a minute's typing.
struct LatencyStats: Sendable, Equatable {
    /// Enough to be stable, short enough to move when conditions do. At roughly
    /// two model passes a second while typing steadily, this is about a minute.
    static let windowSize = 100

    private var samples: [Int] = []

    var count: Int { samples.count }
    var isEmpty: Bool { samples.isEmpty }

    mutating func record(_ milliseconds: Int) {
        // A negative or absurd reading means the clock moved under us, which
        // says nothing about the engine.
        guard milliseconds >= 0, milliseconds < 120_000 else { return }
        samples.append(milliseconds)
        if samples.count > Self.windowSize {
            samples.removeFirst(samples.count - Self.windowSize)
        }
    }

    mutating func reset() { samples.removeAll() }

    /// Nearest-rank, which needs no interpolation and cannot invent a value
    /// that was never measured. `percentile(0.5)` is the median.
    func percentile(_ fraction: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    var median: Int? { percentile(0.5) }
    /// The slow end people actually notice, rather than the single worst
    /// reading, which is usually the first request against a cold cache.
    var ninetieth: Int? { percentile(0.9) }
    var slowest: Int? { samples.max() }

    /// One line for the settings row.
    var summary: String {
        guard let median, let ninetieth else { return "Not measured yet" }
        return "\(median) ms typical · \(ninetieth) ms slow"
    }
}
