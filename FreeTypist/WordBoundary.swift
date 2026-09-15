import AppKit

enum WordBoundary {
    /// True when the character before the caret ends a complete word.
    ///
    /// This is what decides whether a model continuation needs a space in front
    /// of it: "…time to" is finished (so " read this" is right), while
    /// "unfortun" is half-typed (so "ately" must attach directly).
    ///
    /// Two questions, and the second is the one that was missing. The spell
    /// checker does not flag short fragments at all — "Ar", "Th", "Chr" and "e"
    /// are all spelled fine as far as `checkSpelling` is concerned — so a caret
    /// partway through a short word was reported as ending a complete one, and
    /// "Thank you for reaching out. Ar" accepted its suggestion as
    /// "Ar wa is doing well."
    ///
    /// So the checker's own completion list is asked as well, and a finished
    /// word has to appear in its own: "to", "is", "an", "I", "time", "don't"
    /// and "Christine" all complete themselves, while "Ar", "Th", "Chr", "e"
    /// and "co" only ever complete into something longer.
    ///
    /// An *empty* completion list is not evidence of anything. It is what comes
    /// back for every word the checker can spell but keeps no completions for —
    /// "well-known", "Kubernetes", "PDF", "Arwa" among them — so it leaves
    /// `checkSpelling`'s answer standing rather than overturning it.
    @MainActor
    static func caretEndsCompleteWord(_ before: String) -> Bool {
        guard let last = before.last, last.isLetter || last.isNumber else { return false }
        let word = currentWord(in: before)
        guard !word.isEmpty else { return false }

        return finished.value(for: word) {
            guard NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
            else { return false }
            let offered = completions(for: word)
            return offered.isEmpty || offered.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
    }

    /// The word fragment immediately before the caret, empty when the caret sits
    /// after whitespace.
    @MainActor
    static func currentWord(in text: String) -> String {
        var reversed = ""
        for character in text.reversed() {
            if character.isWhitespace || character.isNewline { break }
            reversed.append(character)
        }
        return String(reversed.reversed())
    }

    /// Typos the system declines to fix, plus cases where it fixes them wrongly.
    ///
    /// Measured: `correction` maps "wich" to "with", where "which" is almost
    /// always meant. The table takes precedence, and the spell checker handles
    /// everything else in the user's own language.
    private static let knownFixes: [String: String] = [
        "teh": "the", "wich": "which", "accomodate": "accommodate",
        "adn": "and", "recieve": "receive", "seperate": "separate",
        "definately": "definitely", "occured": "occurred",
        "neccessary": "necessary", "recomend": "recommend",
        "existance": "existence", "beleive": "believe", "acheive": "achieve",
        "thier": "their", "untill": "until", "arguement": "argument",
        "publically": "publicly",
    ]

    /// Spell lookups repeat constantly: the poll re-reads the same word many
    /// times while the user pauses, and `isMisspelled` consults both of the
    /// lookups below. All of it runs on the main thread, where the key tap's
    /// callback also lives, so the same word is never looked up twice.
    private struct Memo<Value> {
        private var values: [String: Value] = [:]
        private var order: [String] = []
        private let limit = 500

        mutating func value(for key: String, _ compute: () -> Value) -> Value {
            if let hit = values[key] { return hit }
            let value = compute()
            values[key] = value
            order.append(key)
            if order.count > limit { values.removeValue(forKey: order.removeFirst()) }
            return value
        }
    }

    @MainActor private static var corrections = Memo<String?>()
    @MainActor private static var partials = Memo<Bool>()
    /// Keyed on the word as typed, not folded: "I" and "i" are not the same
    /// question to a completion list.
    @MainActor private static var finished = Memo<Bool>()

    /// Everything the checker would offer for a word typed this far.
    @MainActor
    private static func completions(for word: String) -> [String] {
        let checker = NSSpellChecker.shared
        return checker.completions(
            forPartialWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word,
            language: checker.language(),
            inSpellDocumentWithTag: 0
        ) ?? []
    }

    /// True when the word could still become a real one, so the user is partway
    /// through typing it rather than mistaken.
    ///
    /// Neither spelling API has any notion of "unfinished" — both answer about
    /// the string exactly as handed to them, so every partial word of four
    /// letters or more comes back wrong. Measured: "appre" is offered "apple",
    /// "impl" is offered "implement", "unfortun" is offered "unfortunately".
    /// Treating those as typos closed the model pass for most of typing and put
    /// a strikethrough under a word the user was still writing.
    ///
    /// Asking for *completions* is the question that separates the two, and it
    /// separates them cleanly. Measured over the seventeen entries in the table
    /// below plus a further set of arbitrary typos: a real mistake has no
    /// completions at all, while every partial word has between three and
    /// twenty.
    @MainActor
    static func isUnfinished(_ word: String) -> Bool {
        guard isWordLike(word) else { return false }
        return partials.value(for: word.lowercased()) { !completions(for: word).isEmpty }
    }

    /// Whether a word looks wrong enough that a completion should not extend it.
    ///
    /// Three questions, and the order is the point. The table first, because it
    /// is curated and a listed typo is a typo however else it reads. Then
    /// whether the word is merely unfinished, which is what keeps the spell
    /// checker's opinion of a half-typed word from closing the model pass.
    /// Only then the checker itself, and `correction` after it: `checkSpelling`
    /// reports "teh", "wich" and "accomodate" as *fine* while `correction`
    /// offers fixes for all three, so asking only the first misses the
    /// commonest typos in English.
    @MainActor
    static func isMisspelled(_ word: String) -> Bool {
        guard isWordLike(word) else { return false }
        if knownFixes[word.lowercased()] != nil { return true }
        if isUnfinished(word) { return false }
        if NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location != NSNotFound {
            return true
        }
        return correction(for: word) != nil
    }

    /// The suggested fix for a word, or nil if it looks right — or is simply not
    /// finished yet.
    @MainActor
    static func correction(for word: String) -> String? {
        guard isWordLike(word) else { return nil }
        if let known = knownFixes[word.lowercased()] { return known }
        // A word that still opens onto real words is being typed, not misspelt.
        // Without this the fix offered for "appre" is "apple", struck through
        // under a caret that was on its way to "appreciate" — and accepting it
        // replaced the word.
        guard !isUnfinished(word) else { return nil }

        return corrections.value(for: word.lowercased()) {
            let checker = NSSpellChecker.shared
            let range = NSRange(location: 0, length: (word as NSString).length)
            guard let fix = checker.correction(
                forWordRange: range,
                in: word,
                language: checker.language(),
                inSpellDocumentWithTag: 0
            ) else { return nil }
            guard fix.caseInsensitiveCompare(word) != .orderedSame else { return nil }
            return fix
        }
    }

    private static func isWordLike(_ word: String) -> Bool {
        word.count >= 3 && word.allSatisfy { $0.isLetter || $0 == "'" }
    }
}
