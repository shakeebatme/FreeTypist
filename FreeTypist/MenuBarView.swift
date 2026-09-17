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
            // Same words and durations as the Excluded Apps settings pane.
            if preferences.suggestsIn(app.id) {
                Menu("Exclude \(app.name)") {
                    durationButtons { preferences.exclude(app.id, name: app.name, for: $0) }
                }
            } else {
                Button("Stop Excluding \(app.name)") { preferences.include(app.id) }
            }
        }

        if preferences.isEnabled {
            Menu("Exclude All Apps") {
                durationButtons { model.disable(for: $0) }
            }
        } else {
            Button("Stop Excluding All Apps") { model.setEnabled(true) }
        }

        if let app = frontApp, preferences.recordWriting {
            Button("Delete What Was Recorded in \(app.name)") {
                Task { await coordinator.personalization.deleteRecords(forApp: app.id) }
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

    private func durationButtons(_ action: @escaping (ExclusionDuration) -> Void) -> some View {
        ForEach(ExclusionDuration.allCases, id: \.self) { duration in
            Button(duration.title) { action(duration) }
        }
    }
}
