import SwiftUI

/// Completion behaviour and autocorrect.
struct GeneralPane: View {
    @ObservedObject var preferences: Preferences
    @State private var systemSuggestionsOn = SystemTextSuggestions.isEnabled

    private let lengths: [(label: String, words: Int)] = [
        ("Short (~1 – 2 words)", 2),
        ("Medium (~2 – 4 words)", 4),
        ("Long (~6 – 10 words)", 9),
    ]

    var body: some View {
        Section("Completions") {
            Toggle("Enable completions by default", isOn: $preferences.enabledByDefault)
            Text("When off, completions appear only in apps you switch on individually.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Complete inside existing text", isOn: $preferences.midLineCompletions)
            Text("Normally suggestions appear only at the end of a line you have not finished. Turn this on to also get them when text follows the cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Maximum completion length", selection: $preferences.maxWords) {
                ForEach(lengths, id: \.words) { option in
                    Text(option.label).tag(option.words)
                }
            }
            Text("Longer completions take longer to generate and drift further from what you meant. Tab takes them a word at a time regardless.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Autocorrect") {
            Toggle("Don't show completions when a typo is suspected", isOn: $preferences.suppressOnTypo)
            Text("Stops FreeTypist extending a word that already contains a mistake. It only looks at the word you are typing, and is not a spell-checker.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show suggested fixes", isOn: $preferences.showSuggestedFixes)
            Text("When a likely correction exists, strike through the typo and show the fix beside it. Tab accepts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("macOS text suggestions") {
                HStack {
                    Text(systemSuggestionsOn ? "On — may conflict" : "Off")
                        .foregroundStyle(systemSuggestionsOn ? Color.orange : Color.secondary)
                    Button(systemSuggestionsOn ? "Turn Off" : "Turn On") {
                        SystemTextSuggestions.setEnabled(!systemSuggestionsOn)
                        systemSuggestionsOn = SystemTextSuggestions.isEnabled
                    }
                }
            }
            Text("macOS draws its own grey predictions and an autocorrect bubble, which overlap FreeTypist's. This changes a system-wide setting, and apps pick it up when they next launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { systemSuggestionsOn = SystemTextSuggestions.isEnabled }
    }
}
