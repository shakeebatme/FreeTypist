import AppKit
import SwiftUI

/// Settings as a sidebar.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: CompletionCoordinator

    enum Pane: String, CaseIterable, Identifiable {
        case setup, general, context, personalization, emoji
        case shortcuts, battery, apps, perApp, statistics, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .setup: "Setup"
            case .general: "General"
            case .context: "Context"
            case .personalization: "Personalization"
            case .emoji: "Emoji"
            case .shortcuts: "Shortcuts"
            case .battery: "Battery"
            case .apps: "Excluded Apps"
            case .perApp: "Per-App Settings"
            case .statistics: "Statistics"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .setup: "checklist"
            case .general: "gearshape"
            case .context: "rectangle.on.rectangle"
            case .personalization: "wand.and.sparkles"
            case .emoji: "face.smiling"
            case .shortcuts: "command"
            case .battery: "battery.100"
            case .apps: "hand.raised"
            case .perApp: "slider.horizontal.3"
            case .statistics: "chart.bar"
            case .about: "info.circle"
            }
        }
    }

    @State private var selection: Pane = .setup

    private var setupNeedsAttention: Bool {
        SetupStatus.needsAttention(SetupStatus.steps(
            preferences: preferences,
            models: coordinator.models,
            accessibility: model.accessibility
        ))
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                NavigationLink(value: pane) {
                    Label {
                        HStack {
                            Text(pane.title)
                            if pane == .setup, setupNeedsAttention {
                                Spacer()
                                Circle().fill(.orange).frame(width: 6, height: 6)
                            }
                        }
                    } icon: {
                        Image(systemName: pane.symbol)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            Group {
                if selection == .apps {
                    AppSettingsPane(preferences: preferences)
                } else if selection == .perApp {
                    PerAppPane(preferences: preferences)
                } else {
                    Form {
                        detail
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle(selection.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .setup:
            SetupPane(
                preferences: preferences,
                coordinator: coordinator,
                models: coordinator.models,
                accessibility: model.accessibility
            )
        case .general:
            Section("Startup") {
                Toggle("Launch automatically at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.set($0) }
                ))
                Toggle("Show menu bar icon", isOn: $preferences.showMenuBarIcon)
                Text("The menu bar icon gives quick access to settings and per-app controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Model") {
                Text(coordinator.modelStatus.summary)
                    .font(.callout).foregroundStyle(.secondary)
                ModelPicker(repository: coordinator.models, coordinator: coordinator)
            }
            GeneralPane(preferences: preferences)
            UpdatesPane()
        case .context:
            ContextPane(preferences: preferences)
        case .personalization:
            PersonalizationPane(preferences: preferences, coordinator: coordinator)
        case .emoji:
            EmojiPane(preferences: preferences)
            TerminalPane(preferences: preferences)
        case .shortcuts:
            ShortcutsPane(preferences: preferences, shortcuts: coordinator.shortcuts)
        case .battery:
            BatteryPane(preferences: preferences)
        case .apps, .perApp:
            // Laid out outside the form; see `body`.
            EmptyView()
        case .statistics:
            StatisticsPane(coordinator: coordinator)
        case .about:
            AboutPane(coordinator: coordinator)
        }
    }
}
