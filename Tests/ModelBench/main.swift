import AppKit
import Foundation

/// Benchmarks a GGUF through the app's real completion path.
///
/// Usage: modelbench <model.gguf> [...]
/// Prints latency and objective quality flags per prompt so models can be
/// compared on evidence rather than impression.

let prompts: [(label: String, before: String, after: String)] = [
    ("email-open",   "Thanks for taking the time to", ""),
    ("email-follow", "I wanted to follow up on", ""),
    ("email-ask",    "Please let me know if you", ""),
    ("meeting",      "I wanted to let you know that the meeting", ""),
    ("apology",      "Apologies for the delay, I have been", ""),
    ("slack",        "Just pushed the fix — can you", ""),
    ("technical",    "The caret rectangle is reported in", ""),
    ("midword",      "I will investigate this thoroughly and repo", ""),
    ("short",        "Hi Sarah, thanks", ""),
    ("list",         "Next steps: review the draft, then", ""),
]

struct Result {
    let label: String
    let text: String?
    let ms: Int
}

func flags(_ text: String?) -> [String] {
    guard let text, !text.isEmpty else { return ["EMPTY"] }
    var out: [String] = []
    // Template placeholders: the failure mode seen on the 1B model.
    if text.range(of: #"\[[A-Za-z ]+\]"#, options: .regularExpression) != nil { out.append("PLACEHOLDER") }
    // Repeated 3-grams suggest degenerate looping.
    let words = text.split(separator: " ").map(String.init)
    if words.count >= 6 {
        var seen = Set<String>()
        for i in 0..<(words.count - 2) {
            let gram = words[i...i+2].joined(separator: " ").lowercased()
            if !seen.insert(gram).inserted { out.append("REPEAT"); break }
        }
    }
    if words.count > 14 { out.append("OVERLONG") }
    return out
}

@MainActor
func run() async {
    let paths = Array(CommandLine.arguments.dropFirst())
    guard !paths.isEmpty else {
        print("usage: modelbench <model.gguf> [...]")
        exit(2)
    }

    for path in paths {
        let name = (path as NSString).lastPathComponent
        let words = ProcessInfo.processInfo.environment["FT_MAX_WORDS"] ?? "12"
        print("\n════════ \(name)  [maxWords=\(words)] ════════")

        let backend = LlamaBackend()
        let loadStart = Date()
        await backend.load(path: path)
        let status = await backend.status()
        guard status.isReady else {
            print("  load failed: \(status.summary)")
            continue
        }
        print(String(format: "  load %.2fs", Date().timeIntervalSince(loadStart)))
        await backend.warmUp()

        var results: [Result] = []
        for prompt in prompts {
            let request = CompletionRequest(
                before: prompt.before,
                after: prompt.after,
                appName: "Mail",
                instructions: "",
                needsLeadingSpace: WordBoundary.caretEndsCompleteWord(prompt.before),
                maxWords: Int(ProcessInfo.processInfo.environment["FT_MAX_WORDS"] ?? "") ?? 12
            )
            let started = Date()
            let text = await backend.complete(request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            results.append(Result(label: prompt.label, text: text, ms: ms))
        }

        for (index, result) in results.enumerated() {
            let marks = flags(result.text)
            let flagged = marks.isEmpty ? "" : "  ⚠︎ \(marks.joined(separator: ","))"
            let shown = result.text.map { "\"\($0)\"" } ?? "nil"
            print(String(format: "  %-12s %5dms  %@%@",
                         (prompts[index].label as NSString).utf8String!, result.ms, shown, flagged))
        }

        let times = results.map(\.ms).sorted()
        let median = times[times.count / 2]
        let clean = results.filter { flags($0.text).isEmpty }.count
        print(String(format: "  ── median %dms · max %dms · clean %d/%d",
                     median, times.last ?? 0, clean, results.count))

        await backend.unload()
    }
}

await run()
