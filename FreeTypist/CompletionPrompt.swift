import Foundation

/// Assembles the plain-text prompt handed to the model.
///
/// Separate from `LlamaBackend` because it is where every context source the
/// app collects either reaches the model or silently does not — `after` spent
/// the app's life being read, carried through the request, and dropped here —
/// and because a string-building rule should be testable without loading an
/// inference engine to check it.
enum CompletionPrompt {

    /// How much of the text after the caret is worth carrying. Enough for the
    /// top of a quoted message, which is the part that says what the reply is
    /// answering.
    private static let aheadLimit = 600
    /// Below this a block is a fragment, not context.
    private static let minimumBlock = 12
    /// How many of the user's own past lines to carry, and how much of each.
    /// Enough to show a voice, bounded hard: this is the one context source with
    /// no natural ceiling — the store keeps snippets at up to 600 characters and
    /// hands back six per snapshot, which unabridged would bury the sentence
    /// actually being continued.
    private static let phrasingLines = 3
    private static let phrasingLineLimit = 110

    /// Plain-text continuation rather than a chat template: the task is to carry
    /// on the user's sentence, not to answer a question.
    ///
    /// Order matters for more than readability. `before` changes on every
    /// keystroke and every other block changes rarely, so keeping `before` last
    /// is what lets the KV cache reuse the whole prompt prefix between passes.
    static func text(for request: CompletionRequest) -> String {
        var parts: [String] = []
        if !request.instructions.isEmpty {
            parts.append("[Writer's notes: \(request.instructions)]")
        }
        // The user's own past lines. Read from the encrypted store, snapshotted
        // per app and carried on every request since the store was written — and
        // then never assembled here, so "learn my writing" reached the model
        // through the vocabulary logit bias alone and this half did nothing.
        // Sits beside the notes because both describe the writer rather than the
        // moment, and both hold still across keystrokes, which is what keeps the
        // cached prefix reusable.
        let phrasing = request.recentPhrasing
            .prefix(phrasingLines)
            .map { folded($0, limit: phrasingLineLimit) }
            .filter { $0.count >= minimumBlock }
        if !phrasing.isEmpty {
            parts.append("[How this person writes: \(phrasing.joined(separator: " / "))]")
        }
        if let appName = request.appName {
            parts.append("[Writing in \(appName)]")
        }
        if let ocrText = request.ocrText, !ocrText.isEmpty {
            parts.append("[On screen: \(folded(ocrText, limit: aheadLimit))]")
        }
        if let clipboard = request.clipboard, !clipboard.isEmpty {
            parts.append("[Clipboard: \(folded(clipboard, limit: aheadLimit))]")
        }
        // The text after the caret is the most valuable context there is when
        // replying: in a mail client it is the quoted message being answered.
        let ahead = folded(request.after, limit: aheadLimit)
        if ahead.count >= minimumBlock {
            parts.append("[Text after the cursor: \(ahead)]")
        }
        // Who is being written to, and what to call them. Last of the context
        // blocks, so it is the nearest name to the sentence in hand: a small
        // model takes the closest capitalised word that fits, and in a mail
        // client every other name in this prompt is surname-first — the To:
        // token and the attribution line both read "Hodge, Christine" — so a
        // half-typed "Hi C" completed to the surname. Given name first here,
        // and named as the given name, so there is nothing to infer.
        //
        // Derived from `after` and the screen scan rather than from `before`,
        // so it holds still while the greeting is typed and the cached prefix
        // survives it.
        if let name = Correspondent.addressed(in: [request.after, request.ocrText]) {
            parts.append(name.given == name.full
                ? "[Writing to: \(name.given)]"
                : "[Writing to: \(name.full), first name \(name.given)]")
        }
        parts.append(request.before)
        return parts.joined(separator: "\n")
    }

    /// Folds a context block onto one line.
    ///
    /// A multi-line block invites the model to reproduce the block's own shape
    /// instead of continuing the sentence, and the line breaks in a quoted email
    /// or an OCR dump carry no meaning for this purpose.
    static func folded(_ text: String, limit: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }
}
