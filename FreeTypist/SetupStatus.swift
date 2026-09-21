import AppKit
import ApplicationServices
import ServiceManagement

/// One row of the setup checklist.
struct SetupStep: Identifiable {
    enum State {
        case done(String)
        case actionable(String)
        case optional(String)

        var isDone: Bool { if case .done = self { return true }; return false }
        var isRequired: Bool { if case .actionable = self { return true }; return false }
    }

    let id: String
    let title: String
    let detail: String
    let state: State
    /// nil when the step is already satisfied.
    let action: (@MainActor () -> Void)?
}

/// Computes what still needs doing, so the app can say so plainly instead of
/// appearing broken.
///
/// This exists because of a real failure: permission had been granted to a
/// different build, and nothing in the app said so — it simply produced no
/// suggestions.
@MainActor
enum SetupStatus {
    static func steps(
        preferences: Preferences,
        models: ModelRepository,
        accessibility: AccessibilityService
    ) -> [SetupStep] {
        typealias Action = @MainActor () -> Void
        var steps: [SetupStep] = []

        // Ternaries mixing `nil` with a closure blow up type inference here, so
        // each action is built explicitly.
        let trusted = accessibility.isTrusted
        var accessibilityAction: Action? = nil
        if !trusted { accessibilityAction = { accessibility.openSettingsPane() } }
        steps.append(SetupStep(
            id: "accessibility",
            title: "Accessibility permission",
            detail: "Required to read the text around your cursor and insert a suggestion.",
            state: trusted ? SetupStep.State.done("Granted") : SetupStep.State.actionable("Grant"),
            action: accessibilityAction
        ))

        let hasModel = models.loadableModelPath != nil
        var modelAction: Action? = nil
        if !hasModel {
            modelAction = {
                if let spec = models.recommendedForThisMac { models.download(spec) }
            }
        }
        steps.append(SetupStep(
            id: "model",
            title: "AI model",
            detail: hasModel
                ? "Completions run entirely on this Mac."
                : "A model must be downloaded before completions can appear.",
            state: hasModel ? SetupStep.State.done("Downloaded") : SetupStep.State.actionable("Download"),
            action: modelAction
        ))

        // `CGRequestScreenCaptureAccess` shows the system prompt once per app
        // identity and silently does nothing every time after that, so a button
        // wired only to it stops working the moment someone clicks Deny — and
        // looks broken rather than refused. Ask first, then hand over to the
        // pane where the switch actually lives.
        let screen = ScreenCaptureService.hasPermission
        var screenAction: Action? = nil
        if !screen {
            screenAction = {
                if !ScreenCaptureService.requestPermission() {
                    SystemSettings.screenRecording.open()
                }
            }
        }
        steps.append(SetupStep(
            id: "screen",
            title: "Screen Recording permission",
            detail: "Optional. Lets suggestions use what is on screen and stay legible on dark backgrounds. Screenshots are processed locally and never stored.",
            state: screen ? SetupStep.State.done("Granted") : SetupStep.State.optional("Grant"),
            action: screenAction
        ))

        let systemOn = SystemTextSuggestions.isEnabled
        var systemAction: Action? = nil
        if systemOn { systemAction = { SystemTextSuggestions.setEnabled(false) } }
        steps.append(SetupStep(
            id: "macos",
            title: "macOS text suggestions",
            detail: "macOS draws its own grey predictions and autocorrect bubble, which overlap FreeTypist's.",
            state: systemOn ? SetupStep.State.optional("Turn off") : SetupStep.State.done("Disabled"),
            action: systemAction
        ))

        let clipboard = preferences.clipboardContext
        var clipboardAction: Action? = nil
        if !clipboard { clipboardAction = { preferences.clipboardContext = true } }
        steps.append(SetupStep(
            id: "clipboard",
            title: "Clipboard context",
            detail: "Optional. Reads the clipboard while generating a suggestion so it fits what you are working on. Never stored.",
            state: clipboard ? SetupStep.State.done("Enabled") : SetupStep.State.optional("Enable"),
            action: clipboardAction
        ))

        return steps
    }

    /// Headline for the banner: the single next thing worth doing.
    static func summary(for steps: [SetupStep]) -> String? {
        if let blocking = steps.first(where: { $0.state.isRequired }) {
            return "\(blocking.title) is still needed. \(blocking.detail)"
        }
        let optional = steps.filter { if case .optional = $0.state { return true }; return false }
        guard !optional.isEmpty else { return nil }
        if optional.count == 1, let only = optional.first {
            return "One optional step left. \(only.detail)"
        }
        return "\(optional.count) optional steps left. FreeTypist already works without them."
    }

    static func needsAttention(_ steps: [SetupStep]) -> Bool {
        steps.contains { !$0.state.isDone }
    }
}

/// Login item registration.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Where the user can overrule `SMAppService`, for when registering does
    /// not take.
    static func openLoginItems() {
        SystemSettings.loginItems.open()
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.core.error("login item: \(String(describing: error), privacy: .public)")
        }
    }
}
