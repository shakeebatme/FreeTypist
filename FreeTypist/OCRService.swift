import Foundation
import Vision

/// Reads text off captured frames.
///
/// An actor, not a main-actor type, for a specific reason: the CGEvent tap's
/// callback runs on the main run loop, and the system disables a tap whose
/// callback is slow. Recognition must never run there.
actor OCRService {
    /// Default budget, for a single small region such as the caret strip.
    /// Recognition is capped so a slow frame degrades into "no extra context"
    /// rather than a stalled suggestion.
    static let regionBudgetMilliseconds = 160
    /// A whole display is an order of magnitude more pixels than a window band,
    /// so the same 160ms would time out every single time and the scan would
    /// never return anything at all. Affordable only because the screen scan no
    /// longer sits between a keystroke and a suggestion — see
    /// `ScreenContextProvider.startScreenScan`.
    static let screenBudgetMilliseconds = 1_200

    private var busy = false

    struct Outcome: Sendable {
        let lines: [ScreenLine]
        let milliseconds: Int
        let skipped: Bool
        let timedOut: Bool
    }

    /// `fileprivate` so `ResumeGate` below can name it.
    fileprivate enum Finish: Sendable, Equatable {
        case recognized
        case timedOut
    }

    /// Recognises every frame under one shared budget.
    ///
    /// Taking the whole set rather than one frame at a time is what makes a
    /// multi-display scan possible: `busy` is released asynchronously, so
    /// looping over `recognize` per display would have the second call arrive
    /// while the first still held the flag and skip it.
    func recognize(
        _ frames: [CapturedFrame],
        budgetMilliseconds: Int = OCRService.regionBudgetMilliseconds
    ) async -> Outcome {
        guard !frames.isEmpty else {
            return Outcome(lines: [], milliseconds: 0, skipped: true, timedOut: false)
        }
        // Single-flight: overlapping recognitions would queue up behind typing
        // and deliver context for a caret position that no longer exists.
        guard !busy else { return Outcome(lines: [], milliseconds: 0, skipped: true, timedOut: false) }
        busy = true

        let started = ContinuousClock.now
        let deadline = Double(budgetMilliseconds) / 1000
        let collected = LineBox()

        // `VNImageRequestHandler.perform` is synchronous and does not observe
        // task cancellation, so cancelling the work never ended the wait — which
        // is exactly what the previous `Task.cancel()` plus `await work.value`
        // assumed it did, leaving the budget unenforced. The budget is honoured
        // here by resuming without the result and leaving the orphaned
        // recognition to finish into a gate that discards it.
        //
        // Frames are recognised one at a time into `collected`, so a scan that
        // overruns on the second display still hands back the first. Losing the
        // lot on a timeout is what an all-or-nothing hand-off would do, and on a
        // two-display setup that is most scans.
        let finish = await withCheckedContinuation { (continuation: CheckedContinuation<Finish, Never>) in
            let gate = ResumeGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                for frame in frames {
                    collected.append(Self.read(frame))
                    // Nothing downstream will look at further frames once the
                    // deadline has passed, so stop burning cores for them.
                    if gate.isClosed { break }
                }
                gate.resume(with: .recognized)
                // Clearing `busy` here rather than on return is what keeps the
                // single-flight promise across a timeout: the recognition that
                // overran is still holding a core, and starting another one on
                // top of it is how two late frames become four.
                Task { await self.release() }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline) {
                gate.resume(with: .timedOut)
            }
        }

        let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
        return Outcome(
            lines: collected.lines,
            milliseconds: elapsed,
            skipped: false,
            timedOut: finish == .timedOut
        )
    }

    private func release() { busy = false }

    private static func read(_ frame: CapturedFrame) -> [ScreenLine] {
        let request = VNRecognizeTextRequest()
        // Speed over perfection: this is supporting context, not the answer.
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: frame.image, options: [:])
        try? handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ScreenLine(text: text, rect: screenRect(of: observation.boundingBox, in: frame.rect))
        }
    }

    /// Vision reports a normalised box with its origin at the bottom left of the
    /// image; the frame's own rect is Quartz, whose y grows downward. Getting
    /// this flip wrong would not fail loudly — it would quietly rank the top of
    /// the screen as the bottom and drop the wrong lines as "inside the field".
    private static func screenRect(of box: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + box.minX * frame.width,
            y: frame.minY + (1 - box.maxY) * frame.height,
            width: box.width * frame.width,
            height: box.height * frame.height
        )
    }
}

/// Accumulates lines across frames. Written on the recognition queue, read by
/// `recognize` once the budget is settled, so it needs its own lock.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScreenLine] = []

    func append(_ lines: [ScreenLine]) {
        lock.lock()
        storage.append(contentsOf: lines)
        lock.unlock()
    }

    var lines: [ScreenLine] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// One-shot resume: whichever of recognition and the deadline arrives first
/// wins and the loser is discarded. Resuming a continuation twice traps, so the
/// hand-off has to be guarded rather than merely ordered.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OCRService.Finish, Never>?

    init(_ continuation: CheckedContinuation<OCRService.Finish, Never>) {
        self.continuation = continuation
    }

    /// True once someone has taken the resume, so the recognition loop can stop
    /// working on frames nobody is waiting for.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func resume(with finish: OCRService.Finish) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: finish)
    }
}
