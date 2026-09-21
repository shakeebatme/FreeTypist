import Foundation

/// Reading the crash reports macOS already writes.
///
/// The matching is the part worth pinning: too loose and the pane blames
/// FreeTypist for another app's crash, too tight and it reports all-clear
/// while the reports sit on disk.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// MARK: Whose report is it

check("a report for this app matches",
      CrashReports.isReport("FreeTypist-2026-09-20-195412.ips", for: "FreeTypist"))
check("the old .crash format matches too",
      CrashReports.isReport("FreeTypist-2026-09-20-195412.crash", for: "FreeTypist"))

// The real files sitting beside ours today: another binary of this project's
// own, which must not be mistaken for the app.
check("a different binary does not match",
      !CrashReports.isReport("bias-2026-09-20-200833.ips", for: "FreeTypist"))
// A prefix test would claim this one.
check("a longer name does not match",
      !CrashReports.isReport("FreeTypistHelper-2026-09-20-195412.ips", for: "FreeTypist"))
// A contains test would claim this one.
check("a name that merely contains ours does not match",
      !CrashReports.isReport("NotFreeTypist-2026-09-20-195412.ips", for: "FreeTypist"))
check("an unrelated diagnostic does not match",
      !CrashReports.isReport("SFA-ckks.json_2026-09-20-131933_Mac.diag", for: "FreeTypist"))
check("a file with no timestamp does not match",
      !CrashReports.isReport("FreeTypist.ips", for: "FreeTypist"))

// MARK: When

let when = CrashReports.date(fromFileName: "FreeTypist-2026-09-20-195412.ips")
check("the timestamp is read from the name", when != nil)
if let when {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
    check("it reads the right moment",
          parts.year == 2026 && parts.month == 9 && parts.day == 20
          && parts.hour == 19 && parts.minute == 54 && parts.second == 12)
}
check("a malformed name has no date",
      CrashReports.date(fromFileName: "FreeTypist-nonsense.ips") == nil)

// MARK: What killed it

// The shape of the real report this feature found: ggml's atexit handler
// aborting with resource sets still alive.
let ips = #"{"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"indicator":"Abort trap: 6"}}"#
check("an .ips signal is summarised",
      CrashReports.summary(fromReport: ips) == "EXC_CRASH (SIGABRT)")

let crash = "Process: FreeTypist [123]\nException Type:  EXC_BAD_ACCESS (SIGSEGV)\nException Codes: …"
check("an old-style report is summarised",
      CrashReports.summary(fromReport: crash) == "EXC_BAD_ACCESS (SIGSEGV)")

check("an unreadable report still says something",
      CrashReports.summary(fromReport: "") == "Crashed")
check("a report with an exception but no signal still says something",
      CrashReports.summary(fromReport: #"{"exception":{"type":"EXC_GUARD"}}"#) == "EXC_GUARD")

// MARK: Reading the real directory

// Whatever is actually on this machine, the call must not throw or hang, and
// must not claim another binary's crash as ours.
let found = CrashReports.recent(limit: 5)
check("reading the real directory is safe", found.count <= 5)
check("everything found is ours", found.allSatisfy { $0.id.hasPrefix("FreeTypist-") })
check("newest first", zip(found, found.dropFirst()).allSatisfy { $0.date >= $1.date })

print(failures == 0 ? "\nAll crash-report cases passed." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
