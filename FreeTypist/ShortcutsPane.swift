import SwiftUI

struct ShortcutsPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var shortcuts: ShortcutStore

    var body: some View {
        Section("Shortcuts") {
            ForEach(ShortcutAction.allCases, id: \.self) { action in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(action.title)
                        Spacer()
                        ShortcutRecorder(shortcut: binding(for: action))
                            .frame(width: 116, height: 22)
                        Button {
                            shortcuts.set(nil, for: action)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .disabled(shortcuts.shortcut(for: action) == nil)
                    }
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if action == .nextWord {
                    Toggle("Include trailing space", isOn: $preferences.includeTrailingSpace)
                    Text("Accepting a single word also takes the space after it, so you can keep typing immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Include trailing punctuation", isOn: $preferences.includeTrailingPunctuation)
                    Text("Punctuation attached to a word is accepted with it instead of needing another press.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Reset to Defaults") { shortcuts.resetToDefaults() }
        }

        Section("Escape") {
            Picker("When you press Escape", selection: $preferences.escapeBehaviour) {
                ForEach(EscapeBehaviour.allCases, id: \.self) { behaviour in
                    Text(behaviour.title).tag(behaviour)
                }
            }
            Text("This only changes what Escape does while a suggestion is showing. Once it has cleared one, a second press goes straight to the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for action: ShortcutAction) -> Binding<Shortcut?> {
        Binding(
            get: { shortcuts.shortcut(for: action) },
            set: { shortcuts.set($0, for: action) }
        )
    }
}
