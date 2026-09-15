import Foundation

/// Terminals are the one place a wrongly-accepted suggestion can *run*, so the
/// bias here is heavily toward staying quiet.

final class Counter: @unchecked Sendable { var failures = 0 }
let counter = Counter()

func check(_ label: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(label)")
    if !ok { counter.failures += 1 }
}

// MARK: Prompt stripping

check("fish prompt stripped",
      TerminalContext.stripPrompt("macbookair@Mac ~> can you refactor") == "can you refactor")
check("dollar prompt stripped",
      TerminalContext.stripPrompt("user@host project $ please add a test") == "please add a test")
check("TUI box prompt stripped",
      TerminalContext.stripPrompt("│ > explain this function") == "explain this function")
check("chevron prompt stripped",
      TerminalContext.stripPrompt("❯ write the docs") == "write the docs")

check("input line taken from a screen buffer",
      TerminalContext.inputLine(from: "Welcome to fish\nType help\nmacbookair@Mac ~> can you fix the bug")
        == "can you fix the bug")

// MARK: Commands must never be completed

let commands = [
    "git commit -m wip",
    "ls -la",
    "cd ~/Developement && npm test",
    "rm -rf build",
    "./scripts/install.sh",
    "cat file.txt | grep error",
    "swift build",
    "docker compose up",
    "python3 train.py",
    "brew install cmake",
]
let wronglyAccepted = commands.filter { TerminalContext.looksLikePrompt($0) }
check("no shell command treated as prose (\(commands.count - wronglyAccepted.count)/\(commands.count))",
      wronglyAccepted.isEmpty)
for command in wronglyAccepted { print("      would suggest into: \(command)") }

// MARK: Agent prompts should be completed

let prompts = [
    "can you refactor the login handler",
    "please add a test for the parser",
    "why is the build failing on CI",
    "explain what this function is doing",
    "I want to add a new setting for",
]
let missed = prompts.filter { !TerminalContext.looksLikePrompt($0) }
check("agent prompts recognised (\(prompts.count - missed.count)/\(prompts.count))", missed.isEmpty)
for prompt in missed { print("      missed: \(prompt)") }

// MARK: Edge cases

check("empty line is not a prompt", !TerminalContext.looksLikePrompt(""))
check("single word is not a prompt", !TerminalContext.looksLikePrompt("status"))
check("terminals recognised", TerminalContext.isTerminal("com.mitchellh.ghostty"))
check("TextEdit is not a terminal", !TerminalContext.isTerminal("com.apple.TextEdit"))

print(counter.failures == 0 ? "\nAll terminal cases passed." : "\n\(counter.failures) FAILED")
exit(counter.failures == 0 ? 0 : 1)
