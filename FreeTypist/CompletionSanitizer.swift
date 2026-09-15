import Foundation

/// Turns a model's chat-shaped answer back into a raw continuation.
///
/// This is deliberately independent of any particular engine: instruction-tuned
/// models all preface, quote and echo, and the rules below were established by
/// measuring real output rather than guessing. They are covered by a test suite
/// that must stay green across engine swaps — see `Tests/SanitizerTests`.
enum CompletionSanitizer {
    /// - Parameter needsLeadingSpace: decided by the caller, which can reach
    ///   AppKit's spell checker to tell a finished word from a half-typed one.
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
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["continuation:", "completion:", "output:", "answer:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }

        text = stripWrappingQuotes(text)
        text = removeEcho(of: before, from: text)

        // Preserve the user's own spacing decision.
        if before.last?.isWhitespace == true {
            while let first = text.first, first.isWhitespace { text.removeFirst() }
        }

        // Models do not emit a leading space, even when the caret sits
        // immediately after a word. Measured across varied prompts: "…time to"
        // yields "read this…", which would otherwise concatenate into "toread".
        // Only add one when the caller confirmed the caret is at a word boundary,
        // so a half-typed "unfortun" still completes to "unfortunately".
        if needsLeadingSpace,
           let first = text.first, first.isLetter || first.isNumber {
            text = " " + text
        }

        text = truncate(text, limit: limit)

        guard !text.isEmpty else { return nil }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
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
