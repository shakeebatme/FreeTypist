import SwiftUI

/// Per-app behaviour: where suggestions appear and where writing is recorded.
struct AppSettingsPane: View {
    @ObservedObject var preferences: Preferences
    @State private var newBundleID = ""

    private var knownApps: [String] {
        var ids = Set(preferences.perAppEnabled.keys)
        ids.formUnion(preferences.excludedBundleIDs)
        ids.formUnion(preferences.recordingExcludedBundleIDs)
        ids.formUnion(preferences.disabledUntil.keys)
        return ids.sorted()
    }

    var body: some View {
        Section("Apps") {
            if knownApps.isEmpty {
                Text("No per-app settings yet. Add one below, or use the menu bar while an app is in front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(knownApps, id: \.self) { app in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(displayName(for: app))
                        Spacer()
                        Toggle("Suggest", isOn: suggestBinding(for: app))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        Toggle("Record", isOn: recordBinding(for: app))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            // An app excluded from suggestions cannot be
                            // recorded either, so the toggle is not a choice.
                            .disabled(!preferences.recordWriting
                                      || preferences.excludedBundleIDs.contains(app))
                    }
                    if let until = preferences.disabledUntil[app], until > Date() {
                        Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text(app)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                TextField("Bundle identifier", text: $newBundleID)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    preferences.perAppEnabled[trimmed] = preferences.enabledByDefault
                    newBundleID = ""
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Password fields are always skipped, in every app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func displayName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? bundleID
    }

    private func suggestBinding(for app: String) -> Binding<Bool> {
        Binding(
            get: { preferences.suggestsIn(app) },
            set: { value in
                preferences.perAppEnabled[app] = value
                if value {
                    preferences.excludedBundleIDs.remove(app)
                    preferences.disabledUntil[app] = nil
                }
            }
        )
    }

    private func recordBinding(for app: String) -> Binding<Bool> {
        Binding(
            get: { preferences.recordingAllowed(in: app) },
            set: { value in
                if value {
                    preferences.recordingExcludedBundleIDs.remove(app)
                } else {
                    preferences.recordingExcludedBundleIDs.insert(app)
                }
            }
        )
    }
}
