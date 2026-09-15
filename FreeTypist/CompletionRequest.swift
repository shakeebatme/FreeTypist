import Foundation

/// Everything a backend needs to produce one continuation.
///
/// This is the seam the whole app feeds. Context sources (Accessibility, OCR,
/// clipboard), personalization and the user's own instructions all land here, so
/// swapping the engine underneath never invalidates that work.
struct CompletionRequest: Sendable {
    /// Text before the caret, read over Accessibility.
    let before: String
    /// Text after the caret. Carries the quoted original when replying to a
    /// message, so it reaches the prompt as context rather than being dropped.
    let after: String
    /// Screen text Accessibility could not reach — web areas, terminals,
    /// Electron. Populated only when `before` is absent or short, so context is
    /// not duplicated in apps that already answer properly.
    let ocrText: String?
    /// Opt-in, read at request time and never stored.
    let clipboard: String?
    /// Display name of the app being typed in, for prompt framing.
    let appName: String?
    /// The user's own style prompt.
    let instructions: String
    /// Phrases the user has written before, from the personalization store.
    let recentPhrasing: [String]
    /// Learned terms and their frequencies. Drives logit bias at sampling time.
    let vocabulary: [String: Int]
    /// True when the caret ends a complete word, so a continuation starting with
    /// a letter needs a space in front of it.
    let needsLeadingSpace: Bool
    /// Upper bound on the generated continuation.
    let maxWords: Int
    /// 0 = no personalization, 1 = maximum pull toward learned vocabulary.
    let wordChoiceStrength: Double

    init(
        before: String,
        after: String,
        ocrText: String? = nil,
        clipboard: String? = nil,
        appName: String? = nil,
        instructions: String = "",
        recentPhrasing: [String] = [],
        vocabulary: [String: Int] = [:],
        needsLeadingSpace: Bool,
        maxWords: Int = 12,
        wordChoiceStrength: Double = 0
    ) {
        self.before = before
        self.after = after
        self.ocrText = ocrText
        self.clipboard = clipboard
        self.appName = appName
        self.instructions = instructions
        self.recentPhrasing = recentPhrasing
        self.vocabulary = vocabulary
        self.needsLeadingSpace = needsLeadingSpace
        self.maxWords = maxWords
        self.wordChoiceStrength = wordChoiceStrength
    }

    /// A ceiling only — `LlamaBackend` stops on word count, which is what the
    /// user actually chose. Generous enough that the word limit is what bites.
    var tokenBudget: Int { max(8, maxWords * 3) }

    /// Three characters is enough to continue a sentence from — with one
    /// exception. "Hi " is two, and a salutation waiting for a name is the
    /// moment the model has the most to offer and was never asked.
    var hasEnoughContext: Bool {
        before.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
            || Correspondent.isGreeting(before)
    }
}
