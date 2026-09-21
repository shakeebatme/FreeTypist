import Foundation

/// How much FreeTypist has actually done for the user.
///
/// Counts only — how many suggestions were taken and how many words that put
/// in — and never a word of what was written. That is what makes it safe to
/// keep on disk at all, and why it sits in preferences rather than in the
/// encrypted store beside the writing samples.
///
/// Kept across launches because the question it answers is "is this worth
/// having installed?", and a number that resets every morning cannot answer
/// it. The latency window next to it in Settings is deliberately the opposite:
/// that one describes the machine right now, so it starts empty each time.
struct Statistics: Codable, Equatable, Sendable {
    private(set) var accepted = 0
    private(set) var words = 0
    /// When this tally started, so the figures can say what they are a total
    /// of. Set once and moved only by a reset.
    private(set) var since = Date()

    /// One accepted suggestion, and the words it inserted.
    mutating func record(words inserted: Int) {
        // An acceptance that inserted nothing is still an acceptance; a
        // negative count is a caller bug and is not allowed to corrupt a total
        // that now outlives the session.
        accepted += 1
        words += max(0, inserted)
    }

    mutating func reset(now: Date = Date()) {
        accepted = 0
        words = 0
        since = now
    }

    // MARK: - Persistence

    private static let key = "ft.statistics"

    /// Anything unreadable starts again from zero rather than failing: these
    /// are counters, and no total is worth an error dialog.
    static func load(from defaults: UserDefaults) -> Statistics {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Statistics.self, from: data)
        else { return Statistics() }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
