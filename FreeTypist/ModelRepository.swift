import Foundation
import SwiftUI

/// One downloadable GGUF.
struct ModelSpec: Identifiable, Sendable, Hashable {
    enum Tier: Sendable {
        case recommended
        case other
    }

    let id: String
    let name: String
    let repo: String
    let file: String
    let sizeBytes: Int64
    let tier: Tier
    /// The measured best default. Chosen from benchmark results rather than
    /// size alone — see `Tests/ModelBench`.
    let isDefaultChoice: Bool
    /// Shown under the name when it explains a placement.
    let note: String?

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!
    }

    var displaySize: String {
        String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824)
    }
}

/// Catalogue, download and on-disk management for local models.
///
/// Sizes below were measured against the live Hugging Face endpoints rather
/// than copied from anywhere.
@MainActor
final class ModelRepository: ObservableObject {
    /// Tiers come from measurement, not marketing. Benchmarked over ten
    /// realistic prompts (`Tests/ModelBench`), median latency and failure count.
    ///
    /// The first table was measured through a bug, and is kept only to say so.
    /// `LlamaBackend` added the BOS token when the KV cache was empty and omitted
    /// it after that, so of ten prompts in one process exactly the first was well
    /// formed. Qwen sets `add_bos` false and never noticed; Gemma asks for one
    /// and got it once:
    ///
    ///   Qwen 3 1.7B    74ms   10/10 clean
    ///   Qwen 3 4B     160ms   10/10 clean
    ///   Gemma 3 1B     56ms    empty results, incoherent output
    ///   Gemma 3 4B    132ms    degenerate ("you you you", "in in", "then then")
    ///
    /// Re-measured 14 Sep 2026 on the fixed engine, same machine, same prompts,
    /// old and new binaries run back to back:
    ///
    ///   Qwen 3 1.7B   168ms -> 162ms   9/10 -> 9/10   output byte-identical,
    ///                                  which is what `add_bos` false predicts
    ///   Gemma 3 1B     58ms -> 133ms   8/10 ->  7/10   2 empty -> 0 empty
    ///   Qwen 3 4B, Gemma 3 4B          not re-measured
    ///
    /// So the Gemma verdict was two faults read as one. The empty and incoherent
    /// results were the missing BOS and are gone: it now answers every prompt in
    /// whole sentences, and costs more than twice the time precisely because it
    /// is generating something. What remains is real, and is the original
    /// diagnosis — the instruction-tuned Gemmas fill in template slots, "[topic]",
    /// "[Date]", "[Time]", which is useless inline — so they stay in `.other`.
    ///
    /// Two cautions about the numbers themselves. Gemma's *clean* count fell from
    /// 8 to 7 while its output plainly improved, because `flags` scores what a
    /// completion contains and a two-word non-answer contains nothing to catch;
    /// it rewards saying less. And Qwen's 74ms above does not reproduce here on
    /// either engine, so the old table is stale beyond the part this bug touched.
    static let catalogue: [ModelSpec] = [
        ModelSpec(id: "qwen3-1.7b", name: "Qwen 3 1.7B",
                  repo: "ggml-org/Qwen3-1.7B-GGUF",
                  file: "Qwen3-1.7B-Q4_K_M.gguf",
                  sizeBytes: 1_277_752_115, tier: .recommended,
                  isDefaultChoice: true, note: "Fastest coherent option"),
        ModelSpec(id: "qwen3-4b", name: "Qwen 3 4B",
                  repo: "ggml-org/Qwen3-4B-GGUF",
                  file: "Qwen3-4B-Q4_K_M.gguf",
                  sizeBytes: 2_502_129_090, tier: .recommended,
                  isDefaultChoice: false, note: "Slightly richer, about twice as slow"),
        ModelSpec(id: "gemma-3-1b", name: "Gemma 3 1B",
                  repo: "ggml-org/gemma-3-1b-it-GGUF",
                  file: "gemma-3-1b-it-Q4_K_M.gguf",
                  sizeBytes: 805_306_368, tier: .other,
                  isDefaultChoice: false, note: "Coherent, but fills in [placeholders]"),
        ModelSpec(id: "gemma-3-4b", name: "Gemma 3 4B",
                  repo: "ggml-org/gemma-3-4b-it-GGUF",
                  file: "gemma-3-4b-it-Q4_K_M.gguf",
                  sizeBytes: 2_491_416_474, tier: .other,
                  isDefaultChoice: false, note: "Repeats words on raw text"),
    ]

    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?

    @Published var selectedID: String? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "ft.selectedModel") }
    }

    private var task: URLSessionDownloadTask?

    init() {
        selectedID = UserDefaults.standard.string(forKey: "ft.selectedModel")
        refreshInstalled()
        if selectedID == nil {
            selectedID = installedIDs.first ?? recommendedForThisMac?.id
        }
    }

    // MARK: - Locations

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FreeTypist/Models", isDirectory: true)
    }

    func localURL(for spec: ModelSpec) -> URL {
        Self.directory.appendingPathComponent(spec.file)
    }

    func isInstalled(_ spec: ModelSpec) -> Bool {
        installedIDs.contains(spec.id)
    }

    var selectedSpec: ModelSpec? {
        guard let selectedID else { return nil }
        return Self.catalogue.first { $0.id == selectedID }
    }

    /// Path of the model that should actually be loaded, if it is on disk.
    var loadableModelPath: String? {
        guard let spec = selectedSpec, isInstalled(spec) else { return nil }
        return localURL(for: spec).path
    }

    func refreshInstalled() {
        let fileManager = FileManager.default
        installedIDs = Set(Self.catalogue.filter { spec in
            let url = localURL(for: spec)
            guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 else {
                return false
            }
            // A part-written file from an interrupted download must not count as
            // installed, or the engine fails to load with no explanation.
            return size > spec.sizeBytes / 2
        }.map(\.id))
    }

    // MARK: - Recommendation

    /// Models worth offering on this Mac at all.
    var recommendedSection: [ModelSpec] {
        let ceiling = Double(ProcessInfo.processInfo.physicalMemory) * 0.40
        return Self.catalogue.filter { $0.tier == .recommended && Double($0.sizeBytes) <= ceiling }
    }

    var otherSection: [ModelSpec] {
        let recommended = Set(recommendedSection.map(\.id))
        return Self.catalogue.filter { !recommended.contains($0.id) }
    }

    /// The one starred as "Recommended for your system".
    ///
    /// Not simply the largest that fits: benchmarking put Qwen 3 1.7B at 74ms
    /// against Qwen 3 4B at 160ms with identical cleanliness, and latency is what
    /// decides whether a suggestion feels instant under the caret.
    var recommendedForThisMac: ModelSpec? {
        let ceiling = Double(ProcessInfo.processInfo.physicalMemory) * 0.25
        let affordable = Self.catalogue.filter {
            $0.tier == .recommended && Double($0.sizeBytes) <= ceiling
        }
        return affordable.first(where: \.isDefaultChoice)
            ?? affordable.max { $0.sizeBytes < $1.sizeBytes }
    }

    // MARK: - Download

    func download(_ spec: ModelSpec) {
        guard downloadingID == nil else { return }
        lastError = nil
        downloadingID = spec.id
        progress = 0

        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let destination = localURL(for: spec)
        let delegate = DownloadDelegate(
            destination: destination,
            onProgress: { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            },
            onFinish: { [weak self] error in
                Task { @MainActor in
                    self?.downloadingID = nil
                    self?.progress = 0
                    self?.lastError = error
                    self?.refreshInstalled()
                    if error == nil { self?.selectedID = spec.id }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.downloadTask(with: spec.url)
        task?.resume()
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
        downloadingID = nil
        progress = 0
    }

    func delete(_ spec: ModelSpec) {
        try? FileManager.default.removeItem(at: localURL(for: spec))
        refreshInstalled()
        if selectedID == spec.id { selectedID = installedIDs.first }
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.directory.path)
    }
}

/// A download delegate rather than `URLSession.bytes`: multi-gigabyte files need
/// a real download task for throughput and byte-accurate progress.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (String?) -> Void

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        onFinish: @escaping @Sendable (String?) -> Void
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish(nil)
        } catch {
            onFinish(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onFinish(error.localizedDescription) }
    }
}
