import Foundation
import SwiftUI

@MainActor
final class Preferences: ObservableObject {
    private enum Key {
        static let enabled = "ft.enabled"
        static let useModel = "ft.useModel"
        static let excluded = "ft.excludedBundleIDs"
        static let maxWords = "ft.maxWords"
        static let screenshotContext = "ft.screenshotContext"
        static let screenshotAppearance = "ft.screenshotAppearance"
        static let clipboardContext = "ft.clipboardContext"
        static let recordWriting = "ft.recordWriting"
        static let recordWithoutAcceptance = "ft.recordWithoutAcceptance"
        static let wordChoiceStrength = "ft.wordChoiceStrength"
        static let recordingExcluded = "ft.recordingExcludedBundleIDs"
        static let enabledByDefault = "ft.enabledByDefault"
        static let midLineCompletions = "ft.midLineCompletions"
        static let suppressOnTypo = "ft.suppressOnTypo"
        static let showSuggestedFixes = "ft.showSuggestedFixes"
        static let perAppEnabled = "ft.perAppEnabled"
        static let escapeBehaviour = "ft.escapeBehaviour"
        static let trailingSpace = "ft.trailingSpace"
        static let trailingPunctuation = "ft.trailingPunctuation"
        static let emojiSuggestions = "ft.emojiSuggestions"
        static let pauseInLowPower = "ft.pauseInLowPower"
        static let showMenuBarIcon = "ft.showMenuBarIcon"
        static let terminalSuggestions = "ft.terminalSuggestions"
    }

    private let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
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

    /// Apps where suggestions still appear but nothing is recorded.
    @Published var recordingExcludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(recordingExcludedBundleIDs), forKey: Key.recordingExcluded) }
    }

    /// When off, suggestions appear only in apps explicitly switched on.
    @Published var enabledByDefault: Bool {
        didSet { defaults.set(enabledByDefault, forKey: Key.enabledByDefault) }
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

    /// Per-app overrides. Present means explicitly set, either way.
    @Published var perAppEnabled: [String: Bool] {
        didSet { defaults.set(perAppEnabled, forKey: Key.perAppEnabled) }
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

    /// Apps switched off for a while, with when they come back.
    @Published var disabledUntil: [String: Date] = [:]

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

    @Published var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs), forKey: Key.excluded) }
    }

    init() {
        defaults.register(defaults: [
            Key.enabled: true, Key.useModel: true, Key.maxWords: 4,
            Key.recordWithoutAcceptance: true, Key.wordChoiceStrength: 0.5,
            Key.enabledByDefault: true, Key.suppressOnTypo: true,
            Key.showSuggestedFixes: true, Key.emojiSuggestions: true,
            Key.pauseInLowPower: true, Key.showMenuBarIcon: true,
        ])
        isEnabled = defaults.bool(forKey: Key.enabled)
        useModel = defaults.bool(forKey: Key.useModel)
        maxWords = defaults.integer(forKey: Key.maxWords)
        screenshotContext = defaults.bool(forKey: Key.screenshotContext)
        screenshotAppearance = defaults.bool(forKey: Key.screenshotAppearance)
        clipboardContext = defaults.bool(forKey: Key.clipboardContext)
        recordWriting = defaults.bool(forKey: Key.recordWriting)
        recordWithoutAcceptance = defaults.bool(forKey: Key.recordWithoutAcceptance)
        wordChoiceStrength = defaults.double(forKey: Key.wordChoiceStrength)
        recordingExcludedBundleIDs = Set(defaults.stringArray(forKey: Key.recordingExcluded) ?? [])
        enabledByDefault = defaults.bool(forKey: Key.enabledByDefault)
        midLineCompletions = defaults.bool(forKey: Key.midLineCompletions)
        suppressOnTypo = defaults.bool(forKey: Key.suppressOnTypo)
        showSuggestedFixes = defaults.bool(forKey: Key.showSuggestedFixes)
        perAppEnabled = defaults.dictionary(forKey: Key.perAppEnabled) as? [String: Bool] ?? [:]
        escapeBehaviour = EscapeBehaviour(rawValue: defaults.string(forKey: Key.escapeBehaviour) ?? "")
            ?? .pauseBriefly
        includeTrailingSpace = defaults.bool(forKey: Key.trailingSpace)
        includeTrailingPunctuation = defaults.bool(forKey: Key.trailingPunctuation)
        emojiSuggestions = defaults.bool(forKey: Key.emojiSuggestions)
        pauseInLowPower = defaults.bool(forKey: Key.pauseInLowPower)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        terminalSuggestions = defaults.bool(forKey: Key.terminalSuggestions)
        let stored = defaults.stringArray(forKey: Key.excluded) ?? [
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.agilebits.onepassword7",
        ]
        excludedBundleIDs = Set(stored)
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    /// Whether suggestions should appear in this app at all.
    func suggestsIn(_ bundleID: String?) -> Bool {
        guard let bundleID else { return enabledByDefault }
        if excludedBundleIDs.contains(bundleID) { return false }
        if let until = disabledUntil[bundleID], until > Date() { return false }
        return perAppEnabled[bundleID] ?? enabledByDefault
    }

    /// Switches an app off for a while, or back on if it already is.
    @discardableResult
    func toggleTemporarily(_ bundleID: String, minutes: Int = 10) -> Bool {
        if let until = disabledUntil[bundleID], until > Date() {
            disabledUntil[bundleID] = nil
            return true
        }
        disabledUntil[bundleID] = Date().addingTimeInterval(Double(minutes) * 60)
        return false
    }

    /// Recording is refused unless it is switched on *and* the app is allowed.
    func mayRecord(_ bundleID: String?) -> Bool {
        guard recordWriting, let bundleID else { return false }
        return recordingAllowed(in: bundleID)
    }

    /// Whether this app would be recorded, ignoring the global switch.
    ///
    /// An app excluded from suggestions is excluded from recording too — the
    /// exclusion list exists for password managers, and recording there would be
    /// far worse than suggesting. The settings toggle must show that, or it
    /// claims recording is on where it is not.
    func recordingAllowed(in bundleID: String) -> Bool {
        !excludedBundleIDs.contains(bundleID)
            && !recordingExcludedBundleIDs.contains(bundleID)
    }
}
