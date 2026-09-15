import SwiftUI

/// A checklist of what is set up and what is not.
///
/// Each row states its own status rather than leaving the user to infer it from
/// the app producing nothing.
struct SetupPane: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: CompletionCoordinator
    @ObservedObject var models: ModelRepository
    let accessibility: AccessibilityService

    @State private var refreshToken = UUID()

    private var steps: [SetupStep] {
        _ = refreshToken
        return SetupStatus.steps(
            preferences: preferences, models: models, accessibility: accessibility
        )
    }

    var body: some View {
        if let summary = SetupStatus.summary(for: steps) {
            Section {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        Section("Setup") {
            ForEach(steps) { step in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        icon(for: step.state)
                        Text(step.title)
                        Spacer()
                        control(for: step)
                    }
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Re-check") { refreshToken = UUID() }
        }

        // Answers "why am I not seeing suggestions?" — including the case the
        // checklist cannot cover, where everything is set up correctly but the
        // app in front does not expose what inline completion needs.
        Section("Status") {
            let diagnosis = { _ = refreshToken; return coordinator.diagnosis }()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: coordinator.isReady
                      ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(coordinator.isReady ? .green : .orange)
                Text(diagnosis)
                    .font(.callout)
                    .foregroundStyle(coordinator.isReady ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Section("Running Copy") {
            Text(accessibility.runningAppPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("macOS grants permission to a specific build, not a path. If suggestions stop after a rebuild, make sure this is the copy you granted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Permissions change outside the app, so re-read whenever it comes forward.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshToken = UUID()
        }
    }

    @ViewBuilder
    private func icon(for state: SetupStep.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .actionable:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .optional:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func control(for step: SetupStep) -> some View {
        switch step.state {
        case .done(let label):
            Text(label).foregroundStyle(.secondary)
        case .actionable(let label), .optional(let label):
            Button(label) {
                step.action?()
                refreshToken = UUID()
            }
        }
    }
}
