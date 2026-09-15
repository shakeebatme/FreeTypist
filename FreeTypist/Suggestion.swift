import Foundation

/// What FreeTypist proposes to insert at the caret.
///
/// `text` is strictly the *continuation* — the characters that do not exist in
/// the document yet. Returning a whole phrase instead is what produced
/// "Thanks for" -> "Thanks forThanks for getting back to me."
struct Suggestion: Sendable, Equatable {
    enum Source: String, Sendable {
        case heuristic
        case model
    }

    let text: String
    /// The text this replaces, sitting immediately before the caret — empty for
    /// an ordinary completion, the misspelled word or the `:shortcode` for a
    /// correction.
    ///
    /// The text itself rather than a count of it, because the four things that
    /// consume it each count differently and only the string can answer them
    /// all: an Accessibility range is measured in UTF-16, a run of backspaces in
    /// grapheme clusters, and a WebKit text-marker walk in marker steps. One
    /// `Int` was being read as each in turn, and they part company on the first
    /// decomposed character — "café" typed as `e` + `◌́` is four characters and
    /// five UTF-16 units, so the selection landed a unit short and replaced the
    /// wrong span.
    let replacing: String
    let source: Source

    init(text: String, replacing: String = "", source: Source) {
        self.text = text
        self.replacing = replacing
        self.source = source
    }

    var isEmpty: Bool { text.isEmpty }

    /// A correction rewrites a word the user already finished; a completion
    /// extends what they are still typing. They deserve different affordances.
    var isCorrection: Bool { !replacing.isEmpty }

    /// The replaced span as Accessibility measures a range: UTF-16 units.
    var replacedRangeLength: Int { (replacing as NSString).length }

    /// The replaced span in characters. One backspace removes one, and one
    /// text-marker step walks back over one, so both paths want this number.
    var replacedCharacterCount: Int { replacing.count }
}

extension Suggestion {
    /// Splits off the leading whitespace plus the first word, so repeated
    /// presses walk through a suggestion one word at a time.
    static func splitFirstWord(
        _ text: String,
        includeTrailingSpace: Bool = false,
        includeTrailingPunctuation: Bool = false
    ) -> (head: String, tail: String) {
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        let wordStart = index
        while index < text.endIndex, !text[index].isWhitespace {
            // Punctuation that *closes* a word is taken with it only when asked.
            // Punctuation inside one is part of it: the apostrophe in "don't"
            // and the hyphen in "well-known" close nothing, and breaking on them
            // put " don" and " well" into the document a press at a time.
            //
            // Two things were wrong. The guard was measured from the start of
            // the *string* rather than of the word, so any leading whitespace —
            // which a continuation almost always has — made it true from the
            // first letter on; and it asked only whether the character was
            // punctuation, never whether anything followed it.
            if !includeTrailingPunctuation, index > wordStart,
               text[index].isPunctuation, !joinsWord(text, at: index) {
                break
            }
            index = text.index(after: index)
        }
        if includeTrailingSpace, index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }
        return (String(text[..<index]), String(text[index...]))
    }

    /// Whether the punctuation at `index` joins two halves of one word rather
    /// than ending it. What follows decides: a letter or a digit means the word
    /// carries on, anything else means this mark was the last of it.
    private static func joinsWord(_ text: String, at index: String.Index) -> Bool {
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }
        return text[next].isLetter || text[next].isNumber
    }
}

/// Produces suggestions from the text surrounding the caret.
protocol CompletionProviding: Sendable {
    func suggest(before: String, after: String) async -> Suggestion?
}
