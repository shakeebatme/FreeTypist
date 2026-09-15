import AppKit
import SwiftUI

/// First-run flow: explain, ask for the permission that is actually required,
/// offer the optional one, download a model, then let the user say how they
/// write.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, accessibility, screenRecording, model, download, personalize

        var isLast: Bool { self == .personalize }
    }

    private static let completedKey = "ft.onboardingCompleted"

    @Published var step: Step = .welcome
    @Published var demoAccepted = false
    @Published var instructions: String = UserInstructions.current
    @Published var personalize = false
    @Published var disableSystemSuggestions = SystemTextSuggestions.isEnabled

    let preferences: Preferences
    let models: ModelRepository
    let accessibility: AccessibilityService

    init(preferences: Preferences, models: ModelRepository, accessibility: AccessibilityService) {
        self.preferences = preferences
        self.models = models
        self.accessibility = accessibility
    }

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// The download step is skipped once a model is already present, so a
    /// returning user is not asked again.
    var visibleSteps: [Step] {
        Step.allCases.filter { step in
            switch step {
            case .download: return models.downloadingID != nil || models.loadableModelPath == nil
            default: return true
            }
        }
    }

    var canAdvance: Bool {
        switch step {
        case .welcome: demoAccepted
        case .accessibility: accessibility.isTrusted
        case .model: models.loadableModelPath != nil || models.downloadingID != nil
        default: true
        }
    }

    var advanceTitle: String {
        switch step {
        case .welcome: "Press ⇥ to Continue"
        case .accessibility: accessibility.isTrusted ? "Next" : "Authorize"
        case .personalize: "Let's Go!"
        default: "Next"
        }
    }

    func advance() {
        if step == .accessibility, !accessibility.isTrusted {
            accessibility.requestAccess()
            accessibility.openSettingsPane()
            return
        }
        guard let index = visibleSteps.firstIndex(of: step) else { return }
        if index + 1 < visibleSteps.count {
            step = visibleSteps[index + 1]
        } else {
            finish()
        }
    }

    func goBack() {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return }
        step = visibleSteps[index - 1]
    }

    var isFirstStep: Bool { visibleSteps.first == step }

    func finish() {
        UserInstructions.set(instructions)
        preferences.recordWriting = personalize
        if disableSystemSuggestions { SystemTextSuggestions.setEnabled(false) }
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        NSApp.keyWindow?.close()
    }
}
