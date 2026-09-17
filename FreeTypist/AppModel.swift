import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let preferences: Preferences
    let coordinator: CompletionCoordinator
    let accessibility: AccessibilityService

    private let reader: FocusedTextReader
    private let inserter: TextInsertionService
    private let overlay: SuggestionOverlayController

    init() {
        let preferences = Preferences()
        let reader = FocusedTextReader()
        let inserter = TextInsertionService(reader: reader)
        let overlay = SuggestionOverlayController()

        self.preferences = preferences
        self.reader = reader
        self.inserter = inserter
        self.overlay = overlay
        self.accessibility = AccessibilityService()
        self.coordinator = CompletionCoordinator(
            reader: reader,
            inserter: inserter,
            overlay: overlay,
            preferences: preferences
        )
        // The coordinator owns the observer; insertion only borrows it to learn
        // when its own write has actually landed.
        inserter.changes = coordinator.changeObserver

        coordinator.start()
        // A timed "exclude all apps" that ran out while the app was not running
        // ends now; one still running picks up where it left off.
        if !preferences.isEnabled { scheduleReenable() }
        UpdateController.start()
        // Deferred: presenting a window from init runs before NSApp has finished
        // launching, and the window never takes focus.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.presentOnboardingIfNeeded()
        }
    }

    /// Changes once, to give the scene something to react to on launch.
    let launchStamp = UUID()

    private let onboardingWindow = OnboardingWindow()
    private let settingsWindow = SettingsWindowController()

    func presentSettings() {
        settingsWindow.present(
            model: self,
            preferences: preferences,
            coordinator: coordinator
        )
    }

    /// Shows the first-run flow when it has never been completed.
    func presentOnboardingIfNeeded() {
        guard !OnboardingModel.hasCompleted else { return }
        let onboarding = OnboardingModel(
            preferences: preferences,
            models: coordinator.models,
            accessibility: accessibility
        )
        onboardingWindow.present(onboarding, models: coordinator.models)
    }

    func presentOnboarding() {
        let onboarding = OnboardingModel(
            preferences: preferences,
            models: coordinator.models,
            accessibility: accessibility
        )
        onboardingWindow.present(onboarding, models: coordinator.models)
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        coordinator.setEnabled(enabled)
    }

    /// Switches completions off in every app, for a while or until switched back on.
    func disable(for duration: ExclusionDuration) {
        setEnabled(false)
        if case .until(let date) = duration.span(from: Date()) {
            preferences.enabledAgainAt = date
            scheduleReenable()
        } else {
            preferences.enabledAgainAt = nil
        }
    }

    /// The end time is saved, not just the timer, so a relaunch does not leave
    /// completions off for good. At the end, nothing happens if the user has
    /// changed their mind since: switched back on, or off with no end.
    private func scheduleReenable() {
        guard let until = preferences.enabledAgainAt else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            guard let self, !self.preferences.isEnabled,
                  let due = self.preferences.enabledAgainAt, due <= Date() else { return }
            self.setEnabled(true)
        }
    }
}
