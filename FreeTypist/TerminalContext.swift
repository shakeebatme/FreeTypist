import Foundation

/// Terminal-aware handling.
///
/// Terminals expose their whole screen buffer as one text area, so the raw
/// "text before the cursor" is the entire scrollback — shell banners and command
/// output included. Feeding that to the model produces continuations of the
/// *output* rather than of what the user is writing.
///
/// They also carry a risk no other app does: a suggestion accepted into a shell
/// command line runs. So completions here are off unless asked for, and are
/// offered only when the line reads as prose — the case where you are typing
/// into an AI agent's prompt rather than composing a command.
enum TerminalContext {
    static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
    ]

    static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    /// The line currently being typed, stripped of any shell or TUI prompt.
    static func inputLine(from before: String) -> String {
        guard let lastLine = before.split(separator: "\n", omittingEmptySubsequences: false).last else {
            return before
        }
        return stripPrompt(String(lastLine))
    }

    /// Removes a leading prompt so the model sees only what the user typed.
    ///
    /// Covers shell prompts ("user@host ~> ", "$ ", "% ") and the box-drawn
    /// prompts TUI agents use ("│ > ").
    static func stripPrompt(_ line: String) -> String {
        var text = line

        // Box drawing used by TUI agents.
        while let first = text.first, "│┃|>❯➜»▌".contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // "user@host path$ " style prompts.
        for marker in ["~> ", "$ ", "% ", "# "] {
            if let range = text.range(of: marker, options: .backwards) {
                text = String(text[range.upperBound...])
                break
            }
        }
        return text
    }

    private static let commandWords: Set<String> = [
        "git", "ls", "cd", "cat", "rm", "cp", "mv", "mkdir", "touch", "chmod",
        "curl", "wget", "ssh", "scp", "grep", "find", "sed", "awk", "echo",
        "npm", "npx", "yarn", "pnpm", "cargo", "go", "python", "python3", "pip",
        "swift", "xcodebuild", "make", "cmake", "docker", "kubectl", "brew",
        "open", "sudo", "vim", "nano", "code", "claude", "man", "which", "ps",
        "kill", "tail", "head", "less", "diff", "tar", "zip", "unzip", "defaults",
    ]

    private static let proseMarkers: Set<String> = [
        "the", "a", "an", "to", "and", "is", "are", "for", "can", "could",
        "please", "i", "we", "you", "it", "this", "that", "should", "would",
        "how", "what", "why", "make", "add", "fix", "write", "explain",
    ]

    /// Whether a line reads as something a person is asking, rather than a
    /// command they are running.
    static func looksLikePrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 8 else { return false }

        // Anything with shell plumbing is a command, whatever else it contains.
        if trimmed.contains(where: { "|&;<>*".contains($0) }) { return false }
        if trimmed.contains("$(") || trimmed.contains("&&") { return false }

        let words = trimmed.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        guard words.count >= 3 else { return false }

        if let first = words.first {
            if commandWords.contains(first) { return false }
            // Paths and flags.
            if first.hasPrefix("./") || first.hasPrefix("/") || first.hasPrefix("-") { return false }
        }

        // Needs at least one ordinary English word to read as a sentence.
        return words.contains { proseMarkers.contains($0) }
    }
}
