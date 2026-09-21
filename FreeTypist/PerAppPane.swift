import AppKit
import SwiftUI

/// Settings that differ in one app.
///
/// Deliberately a separate pane from Excluded Apps. That list answers "should
/// FreeTypist be here at all", this one answers "how should it behave where it
/// is", and folding them together would put a destructive switch next to four
/// fiddly ones.
struct PerAppPane: View {
    @ObservedObject var preferences: Preferences
    @State private var selection: String?
    @State private var runningApps: [RunningApp] = []

    private struct RunningApp: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    /// A tuple cannot be `Identifiable`, and `Table` needs identity to carry a
    /// selection across a refresh.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let summary: String
    }

    private var rows: [Row] {
        preferences.overrides.apps
            .map { Row(id: $0.key, name: InstalledApp.name(for: $0.key), summary: $0.value.summary) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("App") { row in
                    Label {
                        Text(row.name)
                    } icon: {
                        Image(nsImage: InstalledApp.icon(at: InstalledApp.url(for: row.id)))
                    }
                }
                TableColumn("Changes") { row in
                    Text(row.summary)
                        .foregroundStyle(.secondary)
                }
            }
            .tableStyle(.inset)

            HStack(spacing: 6) {
                addMenu
                Button {
                    if let selection { preferences.overrides.remove(selection) }
                    selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)

            Divider()
            editor
        }
        .onAppear(perform: refreshRunningApps)
    }

    @ViewBuilder
    private var editor: some View {
        if let selection {
            Form {
                Section(InstalledApp.name(for: selection)) {
                    // "Default" is a real choice, not the absence of one: it
                    // means keep following the global setting, including when
                    // that setting later changes.
                    Picker("Suggestion length", selection: binding(for: selection, \.maxWords)) {
                        Text("Default").tag(Int?.none)
                        Text("Short (2 words)").tag(Int?.some(2))
                        Text("Medium (4 words)").tag(Int?.some(4))
                        Text("Long (8 words)").tag(Int?.some(8))
                    }
                    toggle("Complete mid-line", selection, \.midLineCompletions)
                    toggle("Suggest emoji", selection, \.emojiSuggestions)
                    toggle("Suggest spelling fixes", selection, \.showSuggestedFixes)
                }
            }
            .formStyle(.grouped)
            .frame(height: 220)
        } else {
            VStack {
                Text(preferences.overrides.isEmpty
                     ? "No apps have their own settings yet."
                     : "Select an app to change its settings.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
    }

    private func toggle(
        _ title: String,
        _ bundleID: String,
        _ field: WritableKeyPath<AppOverrides.Settings, Bool?>
    ) -> some View {
        Picker(title, selection: binding(for: bundleID, field)) {
            Text("Default").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        }
    }

    /// Writes straight through to preferences, which persists on every change.
    /// There is no Save button here and nothing to lose by closing the window.
    private func binding<Value: Equatable>(
        for bundleID: String,
        _ field: WritableKeyPath<AppOverrides.Settings, Value?>
    ) -> Binding<Value?> {
        Binding(
            get: { preferences.overrides[bundleID][keyPath: field] },
            set: { newValue in
                var settings = preferences.overrides[bundleID]
                settings[keyPath: field] = newValue
                preferences.overrides.set(settings, for: bundleID)
                // Clearing the last override removes the app, so the row under
                // the cursor would vanish; let go of it first.
                if settings.isEmpty { selection = nil }
            }
        )
    }

    private var addMenu: some View {
        Menu {
            ForEach(runningApps) { app in
                Button {
                    add(app.id)
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                }
            }
            Divider()
            Button("Choose…") { chooseApp() }
        } label: {
            Image(systemName: "plus")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear(perform: refreshRunningApps)
    }

    /// Added with nothing overridden, which is the honest starting point: the
    /// app is on the list because the user is about to change something, and
    /// the empty entry is what the editor below then fills in.
    private func add(_ bundleID: String) {
        var settings = preferences.overrides[bundleID]
        if settings.isEmpty { settings.maxWords = preferences.maxWords }
        preferences.overrides.set(settings, for: bundleID)
        selection = bundleID
    }

    private func refreshRunningApps() {
        let own = Bundle.main.bundleIdentifier
        var found: [RunningApp] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != own else { continue }
            guard !found.contains(where: { $0.id == id }) else { continue }
            found.append(RunningApp(
                id: id,
                name: app.localizedName ?? InstalledApp.name(for: id),
                icon: InstalledApp.icon(at: app.bundleURL)
            ))
        }
        runningApps = found.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID)
    }
}
