import Foundation

/// Crashes macOS has already recorded for this app.
///
/// No crash-reporting SDK, and none wanted: the README promises that nothing
/// you type leaves the Mac, and a service that uploads stack traces is a
/// service that uploads whatever happened to be in memory. macOS is already
/// writing these reports to disk — the gap was never collection, only that
/// nothing in the app ever said they existed.
///
/// That matters here more than in most apps. FreeTypist runs a C++ inference
/// engine and drives Accessibility against every other app on the Mac, and it
/// has no window: when it dies it simply stops suggesting, which is
/// indistinguishable from a missing permission or an unsupported text field.
enum CrashReports {

    struct Report: Identifiable, Equatable, Sendable {
        let id: String
        let date: Date
        let url: URL
        /// What killed it, as far as the report says.
        let summary: String
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    /// Reports belong to this app when the name before the timestamp matches
    /// exactly. A prefix test would claim "FreeTypistHelper" too, and a
    /// contains test would claim anything.
    static func isReport(_ fileName: String, for executable: String) -> Bool {
        guard fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash") else { return false }
        let stem = fileName.split(separator: ".").dropLast().joined(separator: ".")
        // <name>-<yyyy>-<mm>-<dd>-<hhmmss>
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return false }
        return parts.dropLast(4).joined(separator: "-") == executable
    }

    /// The timestamp macOS puts in the file name, which is local time and the
    /// only date the report carries that does not need the file opened.
    static func date(fromFileName fileName: String) -> Date? {
        let stem = fileName.split(separator: ".").dropLast().joined(separator: ".")
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let stamp = parts.suffix(4).joined(separator: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }

    /// A short cause, from either report format.
    ///
    /// Deliberately shallow. The point is to tell the user *that* it crashed
    /// and give them something to quote in a bug report, not to decode a stack
    /// trace in a settings row.
    static func summary(fromReport contents: String) -> String {
        // Old-style .crash files say it in plain text.
        for line in contents.split(separator: "\n").prefix(40)
        where line.hasPrefix("Exception Type:") {
            let value = line.dropFirst("Exception Type:".count).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        // .ips files are JSON; the signal is the useful half and finding it by
        // name avoids decoding a format Apple keeps changing.
        for token in ["EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_BREAKPOINT",
                      "EXC_ARITHMETIC", "EXC_GUARD", "EXC_RESOURCE", "EXC_CRASH"] {
            guard contents.contains(token) else { continue }
            for signal in ["SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGTRAP", "SIGKILL"]
            where contents.contains(signal) {
                return "\(token) (\(signal))"
            }
            return token
        }
        return "Crashed"
    }

    /// Newest first. Reading is best-effort throughout: a diagnostics row is
    /// never worth an error.
    static func recent(limit: Int = 5, executable: String = "FreeTypist") -> [Report] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }

        return names
            .filter { isReport($0, for: executable) }
            .compactMap { name -> Report? in
                guard let date = date(fromFileName: name) else { return nil }
                let url = directory.appendingPathComponent(name)
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return Report(id: name, date: date, url: url,
                              summary: summary(fromReport: contents))
            }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }
}
