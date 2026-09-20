import Foundation

/// Lifecycle of a downloadable local model.
enum ModelStatus: Sendable, Equatable {
    case noModelSelected
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var summary: String {
        switch self {
        case .noModelSelected: "No model downloaded yet — using built-in phrases."
        case .downloading(let fraction): "Downloading model… \(Int(fraction * 100))%"
        case .loading: "Loading model…"
        case .ready: "Local model ready."
        case .failed(let reason): "Model error: \(reason)"
        }
    }
}

/// A source of model-generated continuations. Kept behind a protocol so the
/// llama.cpp engine can replace this without the coordinator noticing.
protocol ModelBackend: Sendable {
    func status() async -> ModelStatus
    func warmUp() async
    func complete(_ request: CompletionRequest) async -> String?

    /// Up to `count` continuations for the same caret, best first.
    ///
    /// `complete` is this with a count of one, and the hot path uses it: the
    /// extra candidates each cost another pass, and the first has a caret
    /// waiting on it. More are asked for only when the user goes looking.
    ///
    /// Whole list rather than "the others", deliberately. Knowing which
    /// openings to avoid means knowing what the first answer was, and carrying
    /// that between two calls would assume nothing else generated in between —
    /// which an actor shared by every keystroke cannot promise. A backend that
    /// can only manage one returns one.
    func completions(_ request: CompletionRequest, count: Int) async -> [String]
}

extension ModelBackend {
    func completions(_ request: CompletionRequest, count: Int) async -> [String] {
        guard let only = await complete(request) else { return [] }
        return [only]
    }
}

enum ModelBackendFactory {
    static func make() -> (any ModelBackend)? {
        LlamaBackend()
    }
}
