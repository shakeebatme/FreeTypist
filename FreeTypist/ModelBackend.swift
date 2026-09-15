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
}

enum ModelBackendFactory {
    static func make() -> (any ModelBackend)? {
        LlamaBackend()
    }
}
