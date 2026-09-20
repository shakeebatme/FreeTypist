import SwiftUI

/// Model catalogue: a curated Recommended section filtered by this Mac's
/// memory, then everything else.
struct ModelPicker: View {
    @ObservedObject var repository: ModelRepository
    var coordinator: CompletionCoordinator?

    var body: some View {
        if !repository.recommendedSection.isEmpty {
            Text("Recommended")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(repository.recommendedSection) { spec in
                row(spec, starred: spec.id == repository.recommendedForThisMac?.id)
            }
        }

        if !repository.otherSection.isEmpty {
            Text("Other Models")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(repository.otherSection) { spec in
                row(spec, starred: false)
            }
        }

        if let error = repository.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        HStack {
            Button("Reveal Model Files") { repository.revealInFinder() }
            Spacer()
            if repository.downloadingID != nil {
                Button("Cancel Download") { repository.cancelDownload() }
            }
        }
    }

    @ViewBuilder
    private func row(_ spec: ModelSpec, starred: Bool) -> some View {
        HStack(spacing: 8) {
            icon(for: spec)
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name)
                if starred {
                    Text("Recommended for your system")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                } else if let note = spec.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(spec.displaySize)
                .font(.caption)
                .foregroundStyle(.secondary)
            actionButton(for: spec)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard repository.isInstalled(spec) else { return }
            select(spec)
        }
    }

    @ViewBuilder
    private func icon(for spec: ModelSpec) -> some View {
        if repository.downloadingID == spec.id {
            ProgressView(value: repository.progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
        } else if repository.selectedID == spec.id && repository.isInstalled(spec) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if repository.isInstalled(spec) {
            Image(systemName: "circle").foregroundStyle(.secondary)
        } else {
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        }
    }

    @ViewBuilder
    private func actionButton(for spec: ModelSpec) -> some View {
        if repository.downloadingID == spec.id {
            // The percentage sits at 100 while the file is hashed, which for
            // the larger models is a few seconds of apparently nothing.
            Text(repository.isVerifying ? "Checking…" : "\(Int(repository.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if repository.isInstalled(spec) {
            Button("Delete") { repository.delete(spec) }
                .buttonStyle(.link)
        } else {
            Button("Download") { repository.download(spec) }
                .disabled(repository.downloadingID != nil)
        }
    }

    private func select(_ spec: ModelSpec) {
        repository.selectedID = spec.id
        guard let coordinator else { return }
        Task { await coordinator.loadModel() }
    }
}
