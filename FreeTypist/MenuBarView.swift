import AppKit
import SwiftUI

/// Menu bar contents: per-app controls first, then global ones, then the
/// housekeeping items.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: CompletionCoordinator
    @ObservedObject var updates = UpdateController.shared

    private var frontApp: (id: String, name: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? id)
    }

    var body: some View {
        Text(coordinator.statusMessage)
        Text(coordinator.modelStatus.summary)

        Divider()

        if let app = frontApp {
            if preferences.suggestsIn(app.id) {
                Menu("Disable Completions in \(app.name)") {
                    Button("For 10 Minutes") { preferences.disabledUntil[app.id] = pause(10) }
                    Button("For 1 Hour") { preferences.disabledUntil[app.id] = pause(60) }
                    Button("Until Turned Back On") { preferences.perAppEnabled[app.id] = false }
                }
            } else {
                Button("Resume Completions in \(app.name)") {
                    preferences.perAppEnabled[app.id] = true
                    preferences.disabledUntil[app.id] = nil
                    preferences.excludedBundleIDs.remove(app.id)
                }
            }
        }

        if preferences.isEnabled {
            Menu("Disable Completions Globally") {
                Button("For 10 Minutes") { disableGlobally(minutes: 10) }
                Button("For 1 Hour") { disableGlobally(minutes: 60) }
                Button("Until Turned Back On") { model.setEnabled(false) }
            }
        } else {
            Button("Resume Completions") { model.setEnabled(true) }
        }

        if let app = frontApp, preferences.recordWriting {
            Menu("Recording Your Writing in \(app.name)") {
                Toggle("Record Here", isOn: Binding(
                    get: { !preferences.recordingExcludedBundleIDs.contains(app.id) },
                    set: { value in
                        if value {
                            preferences.recordingExcludedBundleIDs.remove(app.id)
                        } else {
                            preferences.recordingExcludedBundleIDs.insert(app.id)
                        }
                    }
                ))
                Button("Delete What Was Recorded Here") {
                    Task { await coordinator.personalization.deleteRecords(forApp: app.id) }
                }
            }
        }

        Divider()

        // Not `SettingsLink`: in an accessory app the responder chain has no
        // target while another app is active, so nothing opens at all.
        Button("FreeTypist Settings") { model.presentSettings() }
            .keyboardShortcut(",", modifiers: .command)

        Button("Reveal Model Files") { coordinator.models.revealInFinder() }

        // Absent in a build with no update signing key, rather than present and
        // permanently greyed out.
        if updates.isConfigured {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheckForUpdates)
        }

        Divider()

        Button("Quit FreeTypist") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func pause(_ minutes: Int) -> Date {
        Date().addingTimeInterval(Double(minutes) * 60)
    }

    private func disableGlobally(minutes: Int) {
        model.setEnabled(false)
        // Re-enable on a timer rather than leaving it off silently.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            model.setEnabled(true)
        }
    }
}
