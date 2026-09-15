import SwiftUI

/// Typing history and custom instructions.
///
/// The copy here is deliberately blunt about what recording means. This is the
/// most invasive thing the app can do, so the user should be able to decide
/// against it from the screen itself rather than from documentation.
struct PersonalizationPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: CompletionCoordinator

    @State private var instructions: String = UserInstructions.current
    @State private var stats: PersonalizationStore.Stats?
    @State private var confirmingDelete = false

    var body: some View {
        Section("Typing History") {
            Toggle("Record my writing for personalization", isOn: $preferences.recordWriting)
            Text("Records what you type in fields where FreeTypist suggests, so completions use your own words and names. Everything is encrypted and stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Not recommended if you regularly write something you would not want stored at all, even locally.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if preferences.recordWriting {
                Toggle("Record even when I accept no suggestion", isOn: $preferences.recordWithoutAcceptance)
                Text("Off means only fields where you accepted at least one completion are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Personalize word choice")
                        Spacer()
                        Text(preferences.wordChoiceStrength < 0.01 ? "Off" : "\(Int(preferences.wordChoiceStrength * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $preferences.wordChoiceStrength, in: 0...1)
                    Text("Nudges the model toward words and phrases you use. Subtle at low values; too high can suggest a less fitting word.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Recorded so far") {
                HStack {
                    Text(statsSummary)
                        .foregroundStyle(.secondary)
                    Button("Delete All…") { confirmingDelete = true }
                        .disabled(stats?.isEmpty ?? true)
                }
            }
        }

        Section("Custom AI Instructions") {
            HStack {
                Text("Tell the model who you are and how you write.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") {
                    UserInstructions.reset()
                    instructions = UserInstructions.seeded
                }
            }
            TextEditor(text: $instructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 96)
                .onChange(of: instructions) { _, value in
                    UserInstructions.set(value)
                }
        }
        .task { await refreshStats() }
        .alert("Delete all recorded writing?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await coordinator.personalization.deleteEverything()
                    await refreshStats()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every stored snippet, the learned vocabulary, and the encryption key. It cannot be undone.")
        }
    }

    private var statsSummary: String {
        guard let stats, !stats.isEmpty else { return "Nothing recorded yet" }
        return "\(stats.snippets) snippets · \(stats.terms) terms"
    }

    private func refreshStats() async {
        stats = await coordinator.personalization.stats()
    }
}
