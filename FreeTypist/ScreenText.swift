import Foundation
import CoreGraphics

/// One recognised line of text and where it sits, in Quartz screen coordinates.
struct ScreenLine: Sendable {
    let text: String
    let rect: CGRect
}

/// Turns a screen-wide OCR dump into the handful of sentences worth putting in
/// a prompt.
///
/// A full-screen scan reads everything: the document being referenced, the
/// conversation being replied to, and also tab titles, sidebar labels, button
/// captions and clock digits. Taking the first 600 characters in reading order
/// — which is what the old window-band scan did, and it only had one window to
/// read — spends the whole budget on whatever happens to sit nearest the top
/// left. So lines are grouped into blocks first and the blocks compete: a
/// paragraph of prose beats a column of chrome, wherever on the screen it is.
///
/// Kept free of AppKit, Vision and ScreenCaptureKit so the ranking rules can be
/// tested without a screen to capture.
enum ScreenText {
    /// Matches `CompletionPrompt.aheadLimit`: anything past it is folded away
    /// by the prompt anyway, so carrying more only costs memory.
    static let characterLimit = 600
    /// Below this a line is chrome — a badge, a button, a truncated tab title.
    private static let minimumLine = 8
    /// Below this a *block* is chrome too, however long its one line is.
    private static let minimumBlock = 40

    /// - Parameters:
    ///   - field: the focused text field, in Quartz coordinates. Lines inside it
    ///     are dropped: that text already reaches the prompt over Accessibility,
    ///     and the half-typed word at the caret is the last thing worth feeding
    ///     back in as "context".
    ///   - known: text the prompt already carries, folded by `fold`.
    static func condense(
        _ lines: [ScreenLine],
        excluding field: CGRect?,
        known: String,
        limit: Int = characterLimit
    ) -> String {
        var seen = Set<String>()
        let kept = lines.compactMap { line -> ScreenLine? in
            let folded = fold(line.text)
            guard folded.count >= minimumLine else { return nil }
            // Mirrored displays, and the same string in a list and its detail
            // pane, otherwise pay for their text twice.
            guard seen.insert(folded).inserted else { return nil }
            if let field, isInside(line.rect, field) { return nil }
            if !known.isEmpty, known.contains(folded) { return nil }
            // Compared in the folded form, carried in its own. `fold`
            // lowercases, and handing the model a lowercased screen costs it
            // every proper noun on it — including the name of the person in the
            // To: field, which is the one thing that field was here to supply.
            return ScreenLine(text: collapse(line.text), rect: line.rect)
        }

        let blocks = group(kept)
            .map { block in (text: block.map(\.text).joined(separator: " "), lines: block.count) }
            .filter { $0.text.count >= minimumBlock }
            // Longest first, so the cut below drops the least useful block
            // rather than the bottom of the screen. Line count breaks ties
            // towards real paragraphs over one long path or URL.
            .sorted { ($0.text.count, $0.lines) > ($1.text.count, $1.lines) }

        // No single block takes more than half the budget while another one is
        // waiting. Measured on a real screen, winner-take-all is not a corner
        // case: a terminal or a long document fills its window with far more
        // text than a reference pane holds, wins on size, and spends all 600
        // characters — so the window the user was reading from, which is the
        // whole reason to scan the screen at all, contributes nothing.
        let share = blocks.count > 1 ? limit / 2 : limit

        var out: [String] = []
        var budget = limit
        for block in blocks {
            guard budget >= minimumBlock else { break }
            let take = min(budget, share)
            out.append(String(block.text.prefix(take)))
            budget -= min(block.text.count, take) + 1
        }
        return out.joined(separator: "\n")
    }

    /// True when a line is substantially within `rect` — OCR boxes bleed a pixel
    /// or two past a field's own bounds, so containment is by overlap, not by
    /// `CGRect.contains`.
    private static func isInside(_ line: CGRect, _ rect: CGRect) -> Bool {
        let overlap = line.intersection(rect)
        guard !overlap.isNull else { return false }
        let area = line.width * line.height
        guard area > 0 else { return false }
        return (overlap.width * overlap.height) / area >= 0.6
    }

    /// Gathers lines into blocks of running text.
    ///
    /// Two lines belong together when the second sits directly under the first
    /// with no more than a line's worth of gap, and their horizontal spans
    /// actually overlap. The overlap test is what keeps two side-by-side windows
    /// — the case this whole scan exists for — from being welded into one
    /// interleaved block.
    private static func group(_ lines: [ScreenLine]) -> [[ScreenLine]] {
        // Quartz y grows downward, so this is reading order.
        let ordered = lines.sorted {
            $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY
        }

        var blocks: [[ScreenLine]] = []
        for line in ordered {
            let index = blocks.indices.last { blocks[$0].last.map { follows(line, $0) } ?? false }
            if let index {
                blocks[index].append(line)
            } else {
                blocks.append([line])
            }
        }
        return blocks
    }

    private static func follows(_ line: ScreenLine, _ previous: ScreenLine) -> Bool {
        let height = max(previous.rect.height, 1)
        let gap = line.rect.minY - previous.rect.maxY
        guard gap > -height * 0.5, gap < height * 1.5 else { return false }

        let overlap = min(line.rect.maxX, previous.rect.maxX) - max(line.rect.minX, previous.rect.minX)
        return overlap >= min(line.rect.width, previous.rect.width) * 0.25
    }

    /// Whitespace-collapsed onto one line, case intact — the form that reaches
    /// the prompt.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased `collapse`, the form both the dedupe and the already-known
    /// test compare in. A comparison key only: see `condense`.
    static func fold(_ text: String) -> String {
        collapse(text).lowercased()
    }
}
