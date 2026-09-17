import Foundation

/// How long an app stays excluded.
enum ExclusionDuration: CaseIterable, Sendable {
    case tenMinutes, oneHour, untilTomorrow, always

    var title: String {
        switch self {
        case .tenMinutes: "For 10 Minutes"
        case .oneHour: "For 1 Hour"
        case .untilTomorrow: "Until Tomorrow"
        case .always: "Always"
        }
    }

    func span(from now: Date, calendar: Calendar = .current) -> AppExclusions.Span {
        switch self {
        case .tenMinutes: .until(now.addingTimeInterval(10 * 60))
        case .oneHour: .until(now.addingTimeInterval(60 * 60))
        case .untilTomorrow:
            .until(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
                   ?? now.addingTimeInterval(24 * 60 * 60))
        case .always: .always
        }
    }
}

/// Apps FreeTypist stays out of entirely: no suggestions, nothing recorded.
///
/// One list replaces what used to be four — a suggestion block list, per-app
/// on/off overrides, unsaved pause timers, and a recording block list — which
/// between them made "is FreeTypist active here?" hard to answer.
struct AppExclusions: Codable, Equatable, Sendable {
    enum Span: Codable, Equatable, Sendable {
        case always
        case until(Date)
    }

    struct Entry: Codable, Equatable, Sendable {
        /// Saved when the app is added, so the row keeps a real name even
        /// after the app is uninstalled.
        var name: String
        var span: Span
    }

    /// Keyed by bundle identifier.
    private(set) var entries: [String: Entry]

    /// Defaults this list has already been given. A default the user removed
    /// is not brought back, and one added in a later version still arrives.
    private(set) var offeredDefaults: Set<String>

    private enum CodingKeys: String, CodingKey { case entries, offeredDefaults }

    init() {
        entries = [:]
        offeredDefaults = []
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([String: Entry].self, forKey: .entries)
        // Saved before offers were tracked, when these were all the defaults.
        offeredDefaults = try container.decodeIfPresent(Set<String>.self, forKey: .offeredDefaults)
            ?? Self.firstDefaults
    }

    /// Password managers, excluded out of the box.
    static let defaults: AppExclusions = {
        var list = AppExclusions()
        list.addNewDefaults()
        return list
    }()

    private static let defaultEntries: [String: Entry] = [
        "com.apple.keychainaccess": Entry(name: "Keychain Access", span: .always),
        "com.apple.Passwords": Entry(name: "Passwords", span: .always),
        "com.1password.1password": Entry(name: "1Password", span: .always),
        "com.agilebits.onepassword7": Entry(name: "1Password 7", span: .always),
    ]

    private static let firstDefaults: Set<String> = [
        "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
    ]

    /// Adds any default this list has not been given yet. Reports whether it did.
    @discardableResult
    mutating func addNewDefaults() -> Bool {
        let new = Set(Self.defaultEntries.keys).subtracting(offeredDefaults)
        guard !new.isEmpty else { return false }
        for id in new where entries[id] == nil {
            entries[id] = Self.defaultEntries[id]
        }
        offeredDefaults.formUnion(new)
        return true
    }

    func excludes(_ bundleID: String?, now: Date = .now) -> Bool {
        guard let bundleID, let entry = entries[bundleID] else { return false }
        return Self.isActive(entry.span, now: now)
    }

    /// Current exclusions, by name, with expired ones left out.
    func active(now: Date = .now) -> [(id: String, entry: Entry)] {
        entries
            .filter { Self.isActive($0.value.span, now: now) }
            .map { (id: $0.key, entry: $0.value) }
            .sorted {
                let order = $0.entry.name.localizedStandardCompare($1.entry.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// Adds the app, or changes how long it is excluded if already listed.
    mutating func exclude(_ bundleID: String, name: String, span: Span) {
        entries[bundleID] = Entry(name: name, span: span)
    }

    mutating func remove(_ bundleID: String) {
        entries[bundleID] = nil
    }

    /// Drops timed exclusions that have run out. Reports whether any did.
    @discardableResult
    mutating func pruneExpired(now: Date = .now) -> Bool {
        let before = entries.count
        entries = entries.filter { Self.isActive($0.value.span, now: now) }
        return entries.count != before
    }

    /// Builds the list from the settings it replaces.
    ///
    /// Anything the user switched off, for suggestions or for recording,
    /// becomes an exclusion. Recording-only exclusions are carried over too:
    /// dropping them would quietly start recording where the user said not to.
    /// Explicit "on" overrides mean nothing once everything is on by default.
    static func migrating(
        excluded: [String]?,
        perAppEnabled: [String: Bool]?,
        recordingExcluded: [String]?,
        name: (String) -> String
    ) -> AppExclusions {
        // Never having saved the old list means it was still the default.
        let blocked = excluded ?? Array(firstDefaults)
        let switchedOff = (perAppEnabled ?? [:]).filter { !$0.value }.map(\.key)
        var result = AppExclusions()
        for id in blocked + switchedOff + (recordingExcluded ?? []) where result.entries[id] == nil {
            result.exclude(id, name: defaultEntries[id]?.name ?? name(id), span: .always)
        }
        // The old list already had its chance at these; later defaults still apply.
        result.offeredDefaults = firstDefaults
        result.addNewDefaults()
        return result
    }

    private static func isActive(_ span: Span, now: Date) -> Bool {
        switch span {
        case .always: true
        case .until(let date): date > now
        }
    }
}
