import OSLog

/// Stream these with:
///   log stream --predicate 'subsystem == "com.freetypist.app"' --level debug
enum Log {
    static let core = Logger(subsystem: "com.freetypist.app", category: "core")
}
