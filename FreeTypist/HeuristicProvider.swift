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

    /// Shortcodes offered inline when someone types `:name`.
    ///
    /// Matched whole, not by prefix: `:fire` is 🔥 and `:fir` is nothing. A
    /// prefix match would fire on half-typed words that happen to follow a
    /// colon, and a colon is common punctuation.
    ///
    /// Sixteen entries before this, which covered a conversation's worth of
    /// reactions and nothing anyone writes in a sentence. Still a hand-written
    /// list rather than the full Unicode set: the whole set is thousands of
    /// names, most of which nobody types, and the value here is in the few
    /// dozen that come up. Duplicate keys in this literal are a *runtime*
    /// crash, not a compile error, which is why a test reads the table.
    /// Exposed for the test that reads it; reading is what catches a duplicate
    /// key, which traps at runtime rather than failing to compile.
    static var emojiTable: [String: String] { emoji }

    private static let emoji: [String: String] = [
        // Faces and reactions
        ":smile": "😄", ":grin": "😁", ":laugh": "😂", ":joy": "😂",
        ":wink": "😉", ":blush": "😊", ":sweat": "😅", ":thinking": "🤔",
        ":think": "🤔", ":neutral": "😐", ":confused": "😕", ":sad": "😢",
        ":cry": "😢", ":sob": "😭", ":angry": "😠", ":rage": "😡",
        ":shocked": "😮", ":scream": "😱", ":sleepy": "😴", ":sunglasses": "😎",
        ":nerd": "🤓", ":celebrate": "🥳", ":shrug": "🤷", ":facepalm": "🤦",
        ":heart_eyes": "😍", ":wink_face": "😜", ":relieved": "😌",

        // Hands and people
        ":thumbsup": "👍", ":thumbsdown": "👎", ":clap": "👏", ":wave": "👋",
        ":pray": "🙏", ":thanks": "🙏", ":ok": "👌", ":point_right": "👉",
        ":point_left": "👈", ":raised_hands": "🙌", ":muscle": "💪",
        ":handshake": "🤝", ":writing": "✍️", ":eyes": "👀", ":brain": "🧠",

        // Marks and status
        ":check": "✅", ":tick": "✅", ":cross": "❌", ":x": "❌",
        ":warning": "⚠️", ":question": "❓", ":exclamation": "❗",
        ":info": "ℹ️", ":star": "⭐", ":sparkles": "✨", ":fire": "🔥",
        ":100": "💯", ":boom": "💥", ":zap": "⚡", ":bulb": "💡",
        ":lock": "🔒", ":unlock": "🔓", ":key": "🔑", ":bell": "🔔",
        ":no_entry": "⛔", ":recycle": "♻️", ":arrow_up": "⬆️",
        ":arrow_down": "⬇️", ":arrow_right": "➡️", ":arrow_left": "⬅️",

        // Work and writing
        ":rocket": "🚀", ":ship": "🚢", ":wrench": "🔧", ":hammer": "🔨",
        ":gear": "⚙️", ":bug": "🐛", ":computer": "💻", ":phone": "📱",
        ":email": "📧", ":mail": "📧", ":calendar": "📅", ":clock": "🕐",
        ":hourglass": "⏳", ":chart": "📊", ":chart_up": "📈",
        ":chart_down": "📉", ":memo": "📝", ":note": "📝", ":book": "📖",
        ":clipboard": "📋", ":folder": "📁", ":page": "📄", ":pin": "📌",
        ":paperclip": "📎", ":link": "🔗", ":search": "🔍", ":printer": "🖨️",
        ":package": "📦", ":label": "🏷️", ":money": "💰", ":card": "💳",
        ":trophy": "🏆", ":medal": "🏅", ":target": "🎯", ":flag": "🚩",

        // Everyday
        ":heart": "❤️", ":broken_heart": "💔", ":party": "🎉", ":tada": "🎉",
        ":gift": "🎁", ":balloon": "🎈", ":cake": "🎂", ":coffee": "☕",
        ":tea": "🍵", ":beer": "🍺", ":wine": "🍷", ":pizza": "🍕",
        ":food": "🍽️", ":apple": "🍎", ":sun": "☀️", ":moon": "🌙",
        ":cloud": "☁️", ":rain": "🌧️", ":snow": "❄️", ":rainbow": "🌈",
        ":earth": "🌍", ":tree": "🌳", ":flower": "🌸", ":dog": "🐶",
        ":cat": "🐱", ":car": "🚗", ":plane": "✈️", ":train": "🚆",
        ":house": "🏠", ":office": "🏢", ":music": "🎵", ":camera": "📷",
        ":movie": "🎬", ":game": "🎮", ":sleep": "💤", ":bath": "🛁",
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
