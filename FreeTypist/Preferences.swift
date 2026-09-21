import Foundation
import SwiftUI

@MainActor
final class Preferences: ObservableObject {
    private enum Key {
        static let enabled = "ft.enabled"
        static let enabledAgainAt = "ft.enabledAgainAt"
        static let useModel = "ft.useModel"
        static let maxWords = "ft.maxWords"
        static let screenshotContext = "ft.screenshotContext"
        static let screenshotAppearance = "ft.screenshotAppearance"
        static let clipboardContext = "ft.clipboardContext"
        static let recordWriting = "ft.recordWriting"
        static let recordWithoutAcceptance = "ft.recordWithoutAcceptance"
        static let wordChoiceStrength = "ft.wordChoiceStrength"
        static let midLineCompletions = "ft.midLineCompletions"
        static let suppressOnTypo = "ft.suppressOnTypo"
        static let showSuggestedFixes = "ft.showSuggestedFixes"
        static let escapeBehaviour = "ft.escapeBehaviour"
        static let trailingSpace = "ft.trailingSpace"
        static let trailingPunctuation = "ft.trailingPunctuation"
        static let emojiSuggestions = "ft.emojiSuggestions"
        static let pauseInLowPower = "ft.pauseInLowPower"
        static let showMenuBarIcon = "ft.showMenuBarIcon"
        static let terminalSuggestions = "ft.terminalSuggestions"
        static let appExclusions = "ft.appExclusions"
        // Replaced by `appExclusions`; read once to carry settings over.
        static let legacyExcluded = "ft.excludedBundleIDs"
        static let legacyRecordingExcluded = "ft.recordingExcludedBundleIDs"
        static let legacyEnabledByDefault = "ft.enabledByDefault"
        static let legacyPerAppEnabled = "ft.perAppEnabled"
    }

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if isEnabled { enabledAgainAt = nil }
        }
    }

    /// When completions switched off in every app come back by themselves.
    /// `nil` while on, or while off until switched back on.
    @Published var enabledAgainAt: Date? {
        didSet { defaults.set(enabledAgainAt, forKey: Key.enabledAgainAt) }
    }

    @Published var useModel: Bool {
        didSet { defaults.set(useModel, forKey: Key.useModel) }
    }

    /// Longer completions are slower and drift further from intent, and Tab
    /// takes them a word at a time anyway. Medium is the default.
    @Published var maxWords: Int {
        didSet { defaults.set(maxWords, forKey: Key.maxWords) }
    }

    /// Reads the screen around the field so completions fit their surroundings.
    @Published var screenshotContext: Bool {
        didSet { defaults.set(screenshotContext, forKey: Key.screenshotContext) }
    }

    /// Samples the colour behind the caret so ghost text stays legible.
    @Published var screenshotAppearance: Bool {
        didSet { defaults.set(screenshotAppearance, forKey: Key.screenshotAppearance) }
    }

    /// Off by default: the clipboard is the most sensitive of the three.
    @Published var clipboardContext: Bool {
        didSet { defaults.set(clipboardContext, forKey: Key.clipboardContext) }
    }

    /// Off by default. This is the most invasive thing the app can do, so it is
    /// something the user turns on, never something they turn off.
    @Published var recordWriting: Bool {
        didSet { defaults.set(recordWriting, forKey: Key.recordWriting) }
    }

    /// When off, only fields where at least one completion was accepted are kept.
    @Published var recordWithoutAcceptance: Bool {
        didSet { defaults.set(recordWithoutAcceptance, forKey: Key.recordWithoutAcceptance) }
    }

    /// 0 = off, 1 = maximum. Drives logit bias toward learned vocabulary.
    @Published var wordChoiceStrength: Double {
        didSet { defaults.set(wordChoiceStrength, forKey: Key.wordChoiceStrength) }
    }

    /// Normally suggestions appear only at the end of an unfinished line.
    @Published var midLineCompletions: Bool {
        didSet { defaults.set(midLineCompletions, forKey: Key.midLineCompletions) }
    }

    /// Never extend a word that already contains a typo.
    @Published var suppressOnTypo: Bool {
        didSet { defaults.set(suppressOnTypo, forKey: Key.suppressOnTypo) }
    }

    @Published var showSuggestedFixes: Bool {
        didSet { defaults.set(showSuggestedFixes, forKey: Key.showSuggestedFixes) }
    }

    /// What Escape does while a suggestion is showing.
    @Published var escapeBehaviour: EscapeBehaviour {
        didSet { defaults.set(escapeBehaviour.rawValue, forKey: Key.escapeBehaviour) }
    }

    /// Accepting one word also takes the space after it.
    @Published var includeTrailingSpace: Bool {
        didSet { defaults.set(includeTrailingSpace, forKey: Key.trailingSpace) }
    }

    /// Accepting one word also takes punctuation attached to it.
    @Published var includeTrailingPunctuation: Bool {
        didSet { defaults.set(includeTrailingPunctuation, forKey: Key.trailingPunctuation) }
    }

    @Published var emojiSuggestions: Bool {
        didSet { defaults.set(emojiSuggestions, forKey: Key.emojiSuggestions) }
    }

    @Published var pauseInLowPower: Bool {
        didSet { defaults.set(pauseInLowPower, forKey: Key.pauseInLowPower) }
    }

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    /// Off by default: a suggestion accepted into a shell command line runs.
    @Published var terminalSuggestions: Bool {
        didSet { defaults.set(terminalSuggestions, forKey: Key.terminalSuggestions) }
    }

    /// Apps FreeTypist stays out of: no suggestions, nothing recorded.
    @Published var exclusions: AppExclusions {
        didSet { saveExclusions() }
    }

    /// Settings that differ in one app. Everything unset defers to the
    /// properties above.
    @Published var overrides: AppOverrides {
        didSet { overrides.save(to: defaults) }
    }

    init() {
        defaults.register(defaults: [
            Key.enabled: true, Key.useModel: true, Key.maxWords: 4,
            Key.recordWithoutAcceptance: true, Key.wordChoiceStrength: 0.5,
            Key.suppressOnTypo: true,
            Key.showSuggestedFixes: true, Key.emojiSuggestions: true,
            Key.pauseInLowPower: true, Key.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        enabledAgainAt = defaults.object(forKey: Key.enabledAgainAt) as? Date
        useModel = defaults.bool(forKey: Key.useModel)
        maxWords = defaults.integer(forKey: Key.maxWords)
        screenshotContext = defaults.bool(forKey: Key.screenshotContext)
        screenshotAppearance = defaults.bool(forKey: Key.screenshotAppearance)
        clipboardContext = defaults.bool(forKey: Key.clipboardContext)
        recordWriting = defaults.bool(forKey: Key.recordWriting)
        recordWithoutAcceptance = defaults.bool(forKey: Key.recordWithoutAcceptance)
        wordChoiceStrength = defaults.double(forKey: Key.wordChoiceStrength)
        midLineCompletions = defaults.bool(forKey: Key.midLineCompletions)
        suppressOnTypo = defaults.bool(forKey: Key.suppressOnTypo)
        showSuggestedFixes = defaults.bool(forKey: Key.showSuggestedFixes)
        escapeBehaviour = EscapeBehaviour(rawValue: defaults.string(forKey: Key.escapeBehaviour) ?? "")
            ?? .pauseBriefly
        includeTrailingSpace = defaults.bool(forKey: Key.trailingSpace)
        includeTrailingPunctuation = defaults.bool(forKey: Key.trailingPunctuation)
        emojiSuggestions = defaults.bool(forKey: Key.emojiSuggestions)
        pauseInLowPower = defaults.bool(forKey: Key.pauseInLowPower)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        terminalSuggestions = defaults.bool(forKey: Key.terminalSuggestions)
        exclusions = Self.loadExclusions(from: defaults)
        overrides = AppOverrides.load(from: defaults)
        pruneExpiredExclusions()
    }

    /// Reads the saved list, or builds it once from the settings it replaced.
    private static func loadExclusions(from defaults: UserDefaults) -> AppExclusions {
        if let data = defaults.data(forKey: Key.appExclusions),
           var saved = try? JSONDecoder().decode(AppExclusions.self, from: data) {
            if saved.addNewDefaults() { save(saved, to: defaults) }
            return saved
        }
        let migrated = AppExclusions.migrating(
            excluded: defaults.stringArray(forKey: Key.legacyExcluded),
            perAppEnabled: defaults.dictionary(forKey: Key.legacyPerAppEnabled) as? [String: Bool],
            recordingExcluded: defaults.stringArray(forKey: Key.legacyRecordingExcluded),
            name: InstalledApp.name(for:)
        )
        if save(migrated, to: defaults) {
            for key in [Key.legacyExcluded, Key.legacyPerAppEnabled,
                        Key.legacyRecordingExcluded, Key.legacyEnabledByDefault] {
                defaults.removeObject(forKey: key)
            }
        }
        return migrated
    }

    private func saveExclusions() {
        Self.save(exclusions, to: defaults)
    }

    @discardableResult
    private static func save(_ exclusions: AppExclusions, to defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(exclusions) else { return false }
        defaults.set(data, forKey: Key.appExclusions)
        return true
    }

    // MARK: - Resolved settings
    //
    // The app being typed in decides, falling back to the global value. Read
    // through these rather than the properties directly, or an override is one
    // that only works where somebody remembered it.

    func maxWords(in bundleID: String?) -> Int {
        overrides[bundleID].maxWords ?? maxWords
    }

    func midLineCompletions(in bundleID: String?) -> Bool {
        overrides[bundleID].midLineCompletions ?? midLineCompletions
    }

    func emojiSuggestions(in bundleID: String?) -> Bool {
        overrides[bundleID].emojiSuggestions ?? emojiSuggestions
    }

    func showSuggestedFixes(in bundleID: String?) -> Bool {
        overrides[bundleID].showSuggestedFixes ?? showSuggestedFixes
    }

    /// Whether suggestions should appear in this app at all.
    func suggestsIn(_ bundleID: String?) -> Bool {
        !exclusions.excludes(bundleID)
    }

    /// Recording is refused unless it is switched on *and* the app is not excluded.
    func mayRecord(_ bundleID: String?) -> Bool {
        guard recordWriting, let bundleID else { return false }
        return !exclusions.excludes(bundleID)
    }

    func exclude(_ bundleID: String, name: String, for duration: ExclusionDuration) {
        exclusions.exclude(bundleID, name: name, span: duration.span(from: Date()))
    }

    func include(_ bundleID: String) {
        exclusions.remove(bundleID)
    }

    /// Assigns only when something ran out, so views are not refreshed for nothing.
    func pruneExpiredExclusions() {
        var pruned = exclusions
        if pruned.pruneExpired() { exclusions = pruned }
    }
}
