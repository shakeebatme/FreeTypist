import Foundation

/// Turns a model's chat-shaped answer back into a raw continuation.
///
/// This is deliberately independent of any particular engine: instruction-tuned
/// models all preface, quote and echo, and the rules below were established by
/// measuring real output rather than guessing. They are covered by a test suite
/// that must stay green across engine swaps — see `Tests/SanitizerTests`.
enum CompletionSanitizer {
    /// - Parameter needsLeadingSpace: the fallback, decided by the caller,
    ///   which can reach AppKit's spell checker to tell a finished word from a
    ///   half-typed one. Consulted only when the model's own answer has been
    ///   lost — see the leading-space rule below.
    static func sanitize(
        _ raw: String,
        before: String,
        needsLeadingSpace: Bool,
        limit: Int = 140
    ) -> String? {
        var text = raw

        if let newline = text.firstIndex(where: { $0.isNewline }) {
            text = String(text[text.startIndex..<newline])
        }
        // Read before anything trims it: whether the model opened with a space
        // is the best evidence there is about whether the caret is sitting
        // mid-word, and it is about to be thrown away.
        let modelOpenedWithSpace = text.first?.isWhitespace == true
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Each of these can rewrite the head of the string, which is where the
        // model put its answer. Once one has, there is nothing left to read and
        // the caller's guess is all there is.
        var headRewritten = false
        for prefix in ["continuation:", "completion:", "output:", "answer:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            headRewritten = true
        }

        let unquoted = stripWrappingQuotes(text)
        if unquoted != text { headRewritten = true }
        text = unquoted

        let unechoed = removeEcho(of: before, from: text)
        if unechoed != text { headRewritten = true }
        text = unechoed

        // Preserve the user's own spacing decision. It outranks both the model
        // and the caller: they typed the space, or chose not to.
        if before.last?.isWhitespace == true {
            while let first = text.first, first.isWhitespace { text.removeFirst() }
        } else if wantsLeadingSpace(model: modelOpenedWithSpace,
                                    caller: needsLeadingSpace,
                                    headRewritten: headRewritten),
                  let first = text.first, first.isLetter || first.isNumber {
            text = " " + text
        }

        text = truncate(text, limit: limit)

        guard !text.isEmpty else { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    /// Whether the continuation should start with a space.
    ///
    /// The model's own leading whitespace decides it. That reverses what this
    /// did before, and the reason is that the premise changed underneath it:
    /// the old rule read "models do not emit a leading space, even when the
    /// caret sits immediately after a word", which was measured against
    /// instruction-tuned checkpoints. The catalogue is base checkpoints now,
    /// and they do emit it — measured over the bench prompts, nine of ten
    /// continuations opened with a space, and the tenth was the one following a
    /// half-typed word, which is exactly the case that must not have one.
    ///
    /// Deciding it lexically instead corrupted text in both directions.
    /// "I am avail" is a finished word to a spell checker *and* a prefix of
    /// longer ones, so a space was forced into the middle of it and the model's
    /// "ble" arrived as " ble". "…we should resched" is not a word, so the
    /// space the model did emit was stripped and " the meeting" arrived as
    /// "the meeting", jammed onto the fragment.
    ///
    /// The caller's answer is still the fallback, for when the rules above have
    /// rewritten the head of the string and taken the model's answer with it.
    ///
    /// Note for whoever puts an instruction-tuned model back in the catalogue:
    /// this needs revisiting, because those really do omit the space and would
    /// concatenate "…time to" with "read this" into "toread".
    private static func wantsLeadingSpace(
        model modelOpenedWithSpace: Bool,
        caller needsLeadingSpace: Bool,
        headRewritten: Bool
    ) -> Bool {
        headRewritten ? needsLeadingSpace : modelOpenedWithSpace
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Strips the part of the existing text that the model repeated back.
    ///
    /// Character-exact matching is not enough: the model re-spaces what it
    /// echoes, so "…time to  Please let me" (two spaces) comes back as
    /// "…time to Please let me know…" and the echo survives, leaving the whole
    /// sentence duplicated on screen. Fall back to comparing words.
    private static func removeEcho(of before: String, from text: String) -> String {
        guard !text.isEmpty else { return text }

        let maxOverlap = min(80, before.count)
        if maxOverlap >= 3 {
            let lowered = text.lowercased()
            for length in stride(from: maxOverlap, through: 3, by: -1)
            where lowered.hasPrefix(String(before.suffix(length)).lowercased()) {
                return String(text.dropFirst(length))
            }
        }

        let beforeWords = before.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !beforeWords.isEmpty else { return text }

        var textWords: [(word: String, end: String.Index)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            textWords.append((text[start..<index].lowercased(), index))
        }
        guard !textWords.isEmpty else { return text }

        let limit = min(beforeWords.count, textWords.count, 16)
        for count in stride(from: limit, through: 1, by: -1)
        where Array(beforeWords.suffix(count)) == textWords.prefix(count).map(\.word) {
            return String(text[textWords[count - 1].end...])
        }

        return text
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let capped = String(text.prefix(limit))
        if let end = capped.lastIndex(where: { ".!?".contains($0) }) {
            return String(capped[...end])
        }
        if let space = capped.lastIndex(of: " ") {
            return String(capped[..<space])
        }
        return capped
    }
}
