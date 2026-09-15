import Foundation

/// Instant, offline suggestions. Runs on every keystroke so the overlay has
/// something to show immediately, before the language model answers.
struct HeuristicProvider: CompletionProviding {
    /// Trigger -> the text that should follow it.
    private static let phrases: [(trigger: String, continuation: String)] = [
        ("thanks for", " getting back to me."),
        ("thank you for", " taking the time to look at this."),
        ("let me", " look into that and get back to you."),
        ("i will", " follow up with an update shortly."),
        ("could you", " share a little more detail?"),
        ("looking forward", " to hearing from you."),
        ("please let me", " know if you have any questions."),
        ("as discussed", ", I'll send the next update shortly."),
        ("to follow up", " on our conversation,"),
        ("i wanted to", " share a quick update."),
        ("just checking", " in to see how things are going."),
        ("sorry for the", " delay in getting back to you."),
        ("happy to", " help with that."),
        ("let me know", " if that works for you."),
        ("i've attached", " the file for your reference."),
        ("apologies for", " the confusion."),
        ("hope you're", " doing well."),
        ("feel free to", " reach out if anything is unclear."),
    ]

    private static let emoji: [String: String] = [
        ":smile": "😄", ":heart": "❤️", ":rocket": "🚀", ":thumbsup": "👍",
        ":party": "🎉", ":check": "✅", ":sparkles": "✨", ":fire": "🔥",
        ":eyes": "👀", ":100": "💯", ":cry": "😢", ":think": "🤔",
        ":wave": "👋", ":pray": "🙏", ":bug": "🐛", ":ship": "🚢",
    ]

    private static let vocabulary = [
        "unfortunately", "appreciate", "available", "conversation", "documentation",
        "implementation", "immediately", "information", "management", "necessary",
        "opportunity", "performance", "requirements", "responsibility", "significant",
        "understanding", "development", "experience", "particularly", "configuration",
    ]

    func suggest(before: String, after: String) async -> Suggestion? {
        await MainActor.run { suggestSync(before: before, after: after) }
    }

    /// Synchronous entry point: the coordinator calls this directly to paint a
    /// suggestion in the same turn as the keystroke.
    @MainActor
    func suggestSync(before: String, after: String, showFixes: Bool = true, emoji emojiEnabled: Bool = true) -> Suggestion? {
        guard !before.isEmpty else { return nil }

        // Only suggest at the end of a line; mid-line insertions are noisy.
        if let next = after.first, !next.isNewline, !next.isWhitespace { return nil }

        let token = currentToken(in: before)

        if !token.isEmpty {
            if emojiEnabled, let replacement = Self.emoji[token.lowercased()] {
                return Suggestion(
                    text: replacement,
                    replacing: token,
                    source: .heuristic
                )
            }
            if showFixes, let fixed = WordBoundary.correction(for: token) {
                return Suggestion(
                    text: matchCapitalization(of: token, to: fixed),
                    replacing: token,
                    source: .heuristic
                )
            }
            if token.count >= 4 {
                let lower = token.lowercased()
                if let word = Self.vocabulary.first(where: { $0.hasPrefix(lower) && $0 != lower }) {
                    return Suggestion(text: String(word.dropFirst(lower.count)), source: .heuristic)
                }
            }
        }

        let normalized = before.lowercased()
        let endsWithSpace = before.last?.isWhitespace ?? false
        for phrase in Self.phrases where normalized.hasSuffix(phrase.trigger) {
            var continuation = phrase.continuation
            if endsWithSpace, continuation.hasPrefix(" ") {
                continuation.removeFirst()
            }
            return Suggestion(text: continuation, source: .heuristic)
        }

        return nil
    }

    /// The word fragment immediately before the caret, empty if the caret sits
    /// after whitespace.
    private func currentToken(in text: String) -> String {
        var token = ""
        for character in text.reversed() {
            if character.isWhitespace || character.isNewline { break }
            token.append(character)
        }
        return String(token.reversed())
    }

    private func matchCapitalization(of original: String, to replacement: String) -> String {
        guard let first = original.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
}
