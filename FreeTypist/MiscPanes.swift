import SwiftUI

/// Screen, clipboard and appearance context.
struct ContextPane: View {
    @ObservedObject var preferences: Preferences
    @State private var permitted = ScreenCaptureService.hasPermission

    var body: some View {
        Section("Screenshots") {
            LabeledContent("Screen Recording") {
                HStack {
                    Text(permitted ? "Granted" : "Not granted")
                        .foregroundStyle(permitted ? Color.green : Color.secondary)
                    if !permitted {
                        Button("Grant") {
                            _ = ScreenCaptureService.requestPermission()
                            permitted = ScreenCaptureService.hasPermission
                        }
                    }
                }
            }
            Toggle("Use screenshots for context", isOn: $preferences.screenshotContext)
                .disabled(!permitted)
            Text("Reads every display so completions fit what is already on screen — including the window you are referring to rather than typing in. Runs in the background between keystrokes.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Use screenshots to improve appearance", isOn: $preferences.screenshotAppearance)
                .disabled(!permitted)
            Text("Samples the colour behind the cursor so the suggestion stays readable on dark backgrounds. May briefly show the purple Screen Recording indicator.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Clipboard") {
            Toggle("Use clipboard for context", isOn: $preferences.clipboardContext)
            Text("Read only while generating a suggestion, never stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            permitted = ScreenCaptureService.hasPermission
        }
    }
}

struct TerminalPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section("Terminals") {
            Toggle("Suggest in terminals", isOn: $preferences.terminalSuggestions)
            Text("Off by default. In a terminal a suggestion you accept becomes part of a command, so FreeTypist stays quiet unless the line reads as something you are asking rather than running — the case where you are typing into an AI agent's prompt.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Recognised: Terminal, iTerm2, Ghostty, kitty, Alacritty, WezTerm, Warp, Hyper.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EmojiPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section("Emoji") {
            Toggle("Suggest emoji from shortcodes", isOn: $preferences.emojiSuggestions)
            Text("Type a colon followed by a name, such as :rocket, and the emoji is offered inline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BatteryPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Section("Battery") {
            Toggle("Pause completions in Low Power Mode", isOn: $preferences.pauseInLowPower)
            Text("Generating a completion uses the GPU. Pausing in Low Power Mode keeps FreeTypist from shortening your battery life when you are trying to preserve it.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
        }
    }
}

struct StatisticsPane: View {
    @ObservedObject var coordinator: CompletionCoordinator

    var body: some View {
        Section("Statistics") {
            LabeledContent("Suggestions accepted", value: "\(coordinator.acceptedCount)")
            LabeledContent("Words inserted", value: "\(coordinator.acceptedWords)")
            Text("Counted since FreeTypist last started. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Update checking. Lives in General, next to Startup, which is where Mac apps
/// have always put it.
struct UpdatesPane: View {
    @ObservedObject var updates = UpdateController.shared

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Section("Updates") {
            if updates.isConfigured {
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)

                Toggle("Download updates in the background", isOn: $updates.automaticallyDownloads)
                    .disabled(!updates.automaticallyChecks)
                Text("Fetches the new version ahead of time so installing it is one click. You are still asked before anything is replaced.")
                    .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Last checked") {
                    HStack {
                        Text(lastCheckText).foregroundStyle(.secondary)
                        Button("Check Now") { updates.checkForUpdates() }
                            .disabled(!updates.canCheckForUpdates)
                    }
                }

                Text("An update check asks GitHub for the current version number. It carries nothing about you and nothing you have typed — but it is a network request, so it is yours to turn off.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This build has no update signing key, so it cannot verify a download and does not check. Run scripts/generate-update-keys.sh to set one up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AboutPane: View {
    @ObservedObject var coordinator: CompletionCoordinator

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static let repo = "https://github.com/shakeebatme/FreeTypist"

    var body: some View {
        Section("About") {
            LabeledContent("Version", value: version)
            LabeledContent("Engine", value: "llama.cpp")
            LabeledContent("Model", value: coordinator.models.selectedSpec?.name ?? "None")
            Text("Everything runs on this Mac. No account, and nothing you type leaves it. The only network calls are the one-time model download and, if you leave it on, a daily check for a new version.")
                .font(.caption).foregroundStyle(.secondary)
        }

        // The GPL asks an interactive program to show its licence and point at
        // the source. This is that notice, not decoration.
        Section("License") {
            Text("FreeTypist is free software under the GNU General Public License v3.0. You may use, study, share and modify it; a version you pass on has to carry the same freedoms.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Link("Source Code", destination: URL(string: Self.repo)!)
                Link("License", destination: URL(string: "\(Self.repo)/blob/main/LICENSE")!)
                Link("Privacy", destination: URL(string: "\(Self.repo)/blob/main/PRIVACY.md")!)
            }
            Text("Copyright © 2026 Shakeeb Ahmed. Comes with absolutely no warranty.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Acknowledgements") {
            LabeledContent("Inference", value: "llama.cpp — MIT")
            LabeledContent("Updates", value: "Sparkle — MIT")
            Text("Models are downloaded separately and carry their own terms: Qwen 3 under Apache 2.0, Gemma 3 under Google's Gemma Terms of Use.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Third-party licenses",
                 destination: URL(string: "\(Self.repo)/blob/main/THIRD-PARTY-LICENSES.md")!)
        }
    }
}
