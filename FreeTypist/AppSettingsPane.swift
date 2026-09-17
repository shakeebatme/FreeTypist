import SwiftUI
import UniformTypeIdentifiers

/// Apps FreeTypist stays out of, always or for a while.
///
/// Laid out outside the settings `Form`: a table is what gives the list
/// selection, the Delete key and a context menu, and a table cannot live in a
/// grouped form.
struct AppSettingsPane: View {
    @ObservedObject var preferences: Preferences
    @State private var selection = Set<String>()
    @State private var runningApps: [RunningApp] = []

    private struct Row: Identifiable {
        let id: String
        let name: String
        let span: AppExclusions.Span
        let url: URL?
    }

    private struct RunningApp: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
    }

    private var rows: [Row] {
        preferences.exclusions.active().map {
            Row(id: $0.id, name: $0.entry.name, span: $0.entry.span, url: InstalledApp.url(for: $0.id))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FreeTypist doesn't suggest or record anything in these apps.")
                .foregroundStyle(.secondary)

            table

            HStack(spacing: 4) {
                addMenu
                Button {
                    remove(selection)
                } label: {
                    Label("Remove", systemImage: "minus")
                        .labelStyle(.iconOnly)
                        .frame(width: 12, height: 12)
                }
                .disabled(selection.isEmpty)
                .help("Remove the selected apps from the list")
            }

            Text("Password fields are always skipped, in every app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear(perform: refreshRunningApps)
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
        .onChange(of: preferences.exclusions) {
            selection.formIntersection(rows.map(\.id))
            refreshRunningApps()
        }
        .task {
            // Timed exclusions end on their own; take them off the list when they do.
            while !Task.isCancelled {
                preferences.pruneExpiredExclusions()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("App") { row in
                HStack(spacing: 6) {
                    Image(nsImage: InstalledApp.icon(at: row.url))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .opacity(row.url == nil ? 0.5 : 1)
                    Text(row.name)
                    if row.url == nil {
                        Text("Not installed")
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.id)
            }
            TableColumn("Excluded") { row in
                Menu {
                    durationButtons(for: [row.id])
                    Divider()
                    Button("Remove from List") { remove([row.id]) }
                } label: {
                    Text(Self.label(for: row.span))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .width(min: 140, ideal: 170, max: 220)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Section("Exclude") {
                    durationButtons(for: ids)
                }
                if ids.count == 1, let id = ids.first, let url = InstalledApp.url(for: id) {
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button("Remove from List") { remove(ids) }
            }
        }
        .onDeleteCommand { remove(selection) }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Excluded Apps",
                    systemImage: "hand.raised",
                    description: Text("FreeTypist suggests in every app. Click + to exclude one.")
                )
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Section("Running Apps") {
                if runningApps.isEmpty {
                    Text("No Other Apps Open")
                }
                ForEach(runningApps) { app in
                    Button {
                        preferences.exclude(app.id, name: app.name, for: .always)
                        selection = [app.id]
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
            Divider()
            Button("Choose App…", action: chooseApps)
        } label: {
            Label("Add App", systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 12, height: 12)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Exclude an app")
    }

    @ViewBuilder
    private func durationButtons(for ids: Set<String>) -> some View {
        ForEach(ExclusionDuration.allCases, id: \.self) { duration in
            Button(duration.title) {
                for id in ids {
                    let name = preferences.exclusions.entries[id]?.name ?? InstalledApp.name(for: id)
                    preferences.exclude(id, name: name, for: duration)
                }
            }
        }
    }

    private func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var exclusions = preferences.exclusions
        ids.forEach { exclusions.remove($0) }
        preferences.exclusions = exclusions
        selection.subtract(ids)
    }

    private func refreshRunningApps() {
        var seen = Set<String>()
        runningApps = NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningApp? in
                guard app.activationPolicy == .regular,
                      let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      !preferences.exclusions.excludes(id),
                      seen.insert(id).inserted else { return nil }
                return RunningApp(
                    id: id,
                    name: app.localizedName ?? InstalledApp.name(for: id),
                    icon: InstalledApp.icon(at: app.bundleURL)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps FreeTypist should stay out of."
        panel.prompt = "Exclude"
        Task {
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                panel.runModal()
            }
            guard response == .OK else { return }
            var added = Set<String>()
            for url in panel.urls {
                guard let id = Bundle(url: url)?.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier else { continue }
                preferences.exclude(id, name: InstalledApp.name(at: url), for: .always)
                added.insert(id)
            }
            if !added.isEmpty { selection = added }
        }
    }

    private static func label(for span: AppExclusions.Span) -> String {
        switch span {
        case .always:
            return "Always"
        case .until(let date):
            let calendar = Calendar.current
            if calendar.isDateInToday(date) {
                return "Until \(date.formatted(date: .omitted, time: .shortened))"
            }
            if calendar.isDateInTomorrow(date), date == calendar.startOfDay(for: date) {
                return "Until Tomorrow"
            }
            return "Until \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}

/// Apps looked up by bundle identifier, for showing them by name and icon.
enum InstalledApp {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Falls back to the bundle identifier for an app that is not installed.
    static func name(for bundleID: String) -> String {
        url(for: bundleID).map(name(at:)) ?? bundleID
    }

    static func name(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Sized for a table row or menu item; the generic app icon when missing.
    static func icon(at url: URL?) -> NSImage {
        let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
