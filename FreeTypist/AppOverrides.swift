import Foundation

/// Settings that differ in one app.
///
/// Excluding an app answers "should FreeTypist be here at all". This answers
/// the softer question underneath it — how it should behave where it *is* —
/// which until now had one answer for the whole Mac. Chat wants four words and
/// emoji; a mail client wants a sentence; an editor wants neither emoji nor a
/// spelling fix rewriting an identifier.
///
/// Every field is optional and nil means "whatever the global setting says".
/// That is the whole design: an override is a deliberate exception, so it has
/// to be distinguishable from a value that merely happens to match. Storing
/// resolved values instead would silently pin an app to today's default and
/// stop following the preference the user later changes.
struct AppOverrides: Codable, Equatable, Sendable {

    struct Settings: Codable, Equatable, Sendable {
        var maxWords: Int?
        var midLineCompletions: Bool?
        var emojiSuggestions: Bool?
        var showSuggestedFixes: Bool?

        var isEmpty: Bool {
            maxWords == nil && midLineCompletions == nil
                && emojiSuggestions == nil && showSuggestedFixes == nil
        }

        /// What the row says about itself in the list, so an app with
        /// overrides can be told from one without opening it.
        var summary: String {
            var parts: [String] = []
            if let maxWords { parts.append("\(maxWords) words") }
            if let midLineCompletions { parts.append(midLineCompletions ? "mid-line" : "no mid-line") }
            if let emojiSuggestions { parts.append(emojiSuggestions ? "emoji" : "no emoji") }
            if let showSuggestedFixes { parts.append(showSuggestedFixes ? "fixes" : "no fixes") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
        }
    }

    private(set) var apps: [String: Settings] = [:]

    init() {}

    /// Never nil: an app nobody has touched simply defers on everything.
    subscript(bundleID: String?) -> Settings {
        guard let bundleID, let found = apps[bundleID] else { return Settings() }
        return found
    }

    /// An entry that overrides nothing is removed rather than kept empty.
    /// Otherwise clearing the last field would leave an app on the list with
    /// nothing to say, which reads as a setting that failed to save.
    mutating func set(_ settings: Settings, for bundleID: String) {
        if settings.isEmpty {
            apps.removeValue(forKey: bundleID)
        } else {
            apps[bundleID] = settings
        }
    }

    mutating func remove(_ bundleID: String) {
        apps.removeValue(forKey: bundleID)
    }

    var isEmpty: Bool { apps.isEmpty }

    // MARK: - Persistence

    private static let key = "ft.appOverrides"

    static func load(from defaults: UserDefaults) -> AppOverrides {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppOverrides.self, from: data)
        else { return AppOverrides() }
        return decoded
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
