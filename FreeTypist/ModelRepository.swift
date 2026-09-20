import CryptoKit
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
    /// SHA-256 of the file's contents, as Hugging Face publishes it.
    ///
    /// Not optional, so a catalogue entry cannot be added without one. This is
    /// the only thing standing between a tampered or truncated download and
    /// ggml parsing it inside the process that holds Accessibility over every
    /// app on the Mac.
    let sha256: String
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
/// Sizes and digests below are the values Hugging Face publishes for each file
/// (`/api/models/<repo>/tree/main`: `size`, and the LFS `oid`, which for these
/// files is the SHA-256 of the contents). Verified by hashing the three models
/// that were already on disk — all three matched the published oid exactly.
///
/// The sizes were wrong before this, every one of them, and one was not even a
/// measurement: Gemma 3 1B was recorded as 805,306,368 bytes, which is 768 MiB
/// to the byte. Nothing noticed because the installed check only asked for half
/// the expected size. It asks for the exact size now, which is what made the
/// discrepancy visible.
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
                  sizeBytes: 1_282_439_264,
                  sha256: "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5",
                  tier: .recommended,
                  isDefaultChoice: true, note: "Fastest coherent option"),
        ModelSpec(id: "qwen3-4b", name: "Qwen 3 4B",
                  repo: "ggml-org/Qwen3-4B-GGUF",
                  file: "Qwen3-4B-Q4_K_M.gguf",
                  sizeBytes: 2_497_280_640,
                  sha256: "ab27b9bfa375a178d6cba48f3ad892b94b7739659dcc7aae8058ce0ffed6b328",
                  tier: .recommended,
                  isDefaultChoice: false, note: "Slightly richer, about twice as slow"),
        ModelSpec(id: "gemma-3-1b", name: "Gemma 3 1B",
                  repo: "ggml-org/gemma-3-1b-it-GGUF",
                  file: "gemma-3-1b-it-Q4_K_M.gguf",
                  sizeBytes: 806_058_240,
                  sha256: "8ccc5cd1f1b3602548715ae25a66ed73fd5dc68a210412eea643eb20eb75a135",
                  tier: .other,
                  isDefaultChoice: false, note: "Coherent, but fills in [placeholders]"),
        ModelSpec(id: "gemma-3-4b", name: "Gemma 3 4B",
                  repo: "ggml-org/gemma-3-4b-it-GGUF",
                  file: "gemma-3-4b-it-Q4_K_M.gguf",
                  sizeBytes: 2_489_757_856,
                  sha256: "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
                  tier: .other,
                  isDefaultChoice: false, note: "Repeats words on raw text"),
    ]

    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var downloadingID: String?
    /// True while the finished download is being hashed. Progress sits at 100%
    /// for the couple of seconds that takes, and a bar that stops at full with
    /// nothing said reads as a hang.
    @Published private(set) var isVerifying = false
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
            // The exact size, not most of it. A part-written file from an
            // interrupted download must not count as installed, or the engine
            // fails to load with no explanation — and "more than half" let a
            // file that was merely close enough through, which is how four
            // wrong sizes sat in the catalogue unnoticed.
            //
            // Cheap enough to run on every launch, which the digest is not:
            // hashing measures at about 540 MB/s here, so the recommended model
            // alone would cost some two and a half seconds of every start. The
            // digest is checked once, where the bytes arrive, and the size
            // stands guard afterwards.
            return size == spec.sizeBytes
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
            spec: spec,
            destination: destination,
            onVerifying: { [weak self] in
                Task { @MainActor in self?.isVerifying = true }
            },
            onProgress: { [weak self] fraction in
                Task { @MainActor in self?.progress = fraction }
            },
            onFinish: { [weak self] error in
                Task { @MainActor in
                    self?.downloadingID = nil
                    self?.isVerifying = false
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
        isVerifying = false
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
    private let spec: ModelSpec
    private let destination: URL
    private let onVerifying: @Sendable () -> Void
    private let onProgress: @Sendable (Double) -> Void
    private let onFinish: @Sendable (String?) -> Void

    init(
        spec: ModelSpec,
        destination: URL,
        onVerifying: @escaping @Sendable () -> Void,
        onProgress: @escaping @Sendable (Double) -> Void,
        onFinish: @escaping @Sendable (String?) -> Void
    ) {
        self.spec = spec
        self.destination = destination
        self.onVerifying = onVerifying
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
        // Checked before it is moved into place, never after. The destination
        // is where `loadableModelPath` looks, so a file that lands there is one
        // the engine may pick up on the next launch; anything that fails here
        // has to be discarded rather than left for the size check to maybe
        // catch later.
        do {
            let size = try FileManager.default
                .attributesOfItem(atPath: location.path)[.size] as? Int64 ?? 0
            guard size == spec.sizeBytes else {
                try? FileManager.default.removeItem(at: location)
                onFinish("The download stopped early, so nothing was installed. Try again.")
                return
            }

            onVerifying()
            guard try Self.sha256(of: location) == spec.sha256 else {
                try? FileManager.default.removeItem(at: location)
                onFinish(
                    "The downloaded file is the right size but does not match its "
                    + "published checksum, so it was discarded. Try again; if it keeps "
                    + "happening, something between here and Hugging Face is altering it."
                )
                return
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            onFinish(nil)
        } catch {
            try? FileManager.default.removeItem(at: location)
            onFinish(error.localizedDescription)
        }
    }

    /// Hashes the file in chunks. These run to gigabytes, so it is never read
    /// into memory whole.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onFinish(error.localizedDescription) }
    }
}
