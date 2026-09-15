import Foundation
import llama

/// Local inference through llama.cpp.
///
/// The engine is deliberately behind `ModelBackend` so the coordinator never
/// learns anything about llama.cpp. Two properties make it viable for
/// autocomplete, where a full re-evaluation on every keystroke would be far too
/// slow:
///
/// - **KV-cache prefix reuse.** Consecutive requests share almost all of their
///   prompt, so only the diverging suffix is decoded.
/// - **Token-level stopping.** Generation halts at a newline or sentence end
///   rather than producing text that is trimmed away afterwards.
actor LlamaBackend: ModelBackend {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?

    private var loadedPath: String?
    private var currentStatus: ModelStatus = .noModelSelected
    /// Tokens currently resident in the KV cache, prompt plus anything since
    /// generated. Compared against the next prompt to find the reusable prefix.
    private var cachedTokens: [llama_token] = []

    private let contextLength: UInt32 = 2048
    /// Tokens per `llama_decode`. This is a hard ceiling, not a hint: the
    /// context asserts rather than erroring if handed more at once.
    private let batchSize: UInt32 = 512
    /// How much to drop at a time when a prompt outgrows the context. See the
    /// truncation in `generate`: the size matters less than the fact that it is
    /// a fixed step rather than an exact fit.
    private let trimBlock = 128

    /// Diagnostics for the KV-cache reuse claim: how much of the last prompt was
    /// already resident versus its total length.
    private var lastPrefixReuse = 0
    private var lastPromptTokens = 0
    /// Whether the last prompt began with the model's BOS token.
    private var lastPromptBeganWithBOS = false
    /// How often each of the two loop exits that can desynchronise the cache
    /// record has actually fired, for the life of this backend.
    private var degenerateStops = 0
    private var decodeFailures = 0
    /// Rebuilding the sampler is cheap but not free; only do it when the bias
    /// actually changes.
    private var biasSignature = ""

    init() {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }

    // No `deinit`: actor state cannot be touched from a nonisolated deinit under
    // strict concurrency, and this backend lives for the life of the process.
    // Call `unload()` to release the model explicitly (switching models does).

    // MARK: - Diagnostics

    /// What the last generation did with the KV cache, and whether the prompt it
    /// decoded was well formed.
    ///
    /// Both are load-bearing claims that were otherwise visible only in a log
    /// line, and a claim nothing can assert is one that quietly stops being
    /// true: prefix reuse across keystrokes is the whole reason inference is
    /// affordable under a caret, and a prompt missing the BOS the model was
    /// trained to expect degrades output without changing a single timing.
    struct Diagnostics: Sendable {
        /// Prompt tokens already resident in the cache, and the prompt's length.
        let shared: Int
        let promptTokens: Int
        /// Whether the prompt handed to `llama_decode` began with BOS, and
        /// whether this model asks for one at all. Not every family does —
        /// Qwen sets `add_bos` false — so the second is what makes the first
        /// meaningful.
        let beganWithBOS: Bool
        let wantsBOS: Bool
        /// Tokens the bookkeeping claims are resident, against the number the
        /// cache actually holds. They must match: `cachedTokens` is what the
        /// next request measures its shared prefix against and then trims to, so
        /// a record running ahead of the truth makes it keep a prefix that was
        /// never there and decode the rest against a short context.
        let trackedTokens: Int
        let residentTokens: Int
        /// Cumulative counts of the two exits that used to leave the record
        /// ahead of the cache, so how often they fire is a measurement rather
        /// than an assumption.
        let degenerateStops: Int
        let decodeFailures: Int

        var reuseFraction: Double {
            promptTokens > 0 ? Double(shared) / Double(promptTokens) : 0
        }
        var cacheIsConsistent: Bool { trackedTokens == residentTokens }
    }

    func diagnostics() -> Diagnostics {
        Diagnostics(
            shared: lastPrefixReuse,
            promptTokens: lastPromptTokens,
            beganWithBOS: lastPromptBeganWithBOS,
            wantsBOS: vocab.map { llama_vocab_get_add_bos($0) } ?? false,
            trackedTokens: cachedTokens.count,
            residentTokens: residentTokenCount(),
            degenerateStops: degenerateStops,
            decodeFailures: decodeFailures
        )
    }

    /// How many tokens sequence 0 really holds, asked of llama.cpp rather than
    /// inferred. Positions are contiguous from 0, so the largest present is one
    /// less than the count, and -1 means empty.
    private func residentTokenCount() -> Int {
        guard let context, let memory = llama_get_memory(context) else { return 0 }
        let highest = llama_memory_seq_pos_max(memory, 0)
        return highest < 0 ? 0 : Int(highest) + 1
    }

    // MARK: - Lifecycle

    func status() async -> ModelStatus { currentStatus }

    func setStatus(_ status: ModelStatus) { currentStatus = status }

    /// Loads a GGUF from disk. Safe to call repeatedly; reloading the same path
    /// is a no-op so the warm KV cache survives.
    func load(path: String) {
        guard loadedPath != path else { return }
        unload()

        guard FileManager.default.fileExists(atPath: path) else {
            currentStatus = .failed("model file missing")
            return
        }

        currentStatus = .loading

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999  // Apple Silicon: keep every layer on Metal.

        guard let loaded = path.withCString({ llama_model_load_from_file($0, modelParams) }) else {
            currentStatus = .failed("could not load model")
            return
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextLength
        contextParams.n_batch = batchSize
        contextParams.no_perf = true
        let cores = Int32(ProcessInfo.processInfo.activeProcessorCount)
        contextParams.n_threads = max(2, cores / 2)
        contextParams.n_threads_batch = contextParams.n_threads

        guard let ctx = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            currentStatus = .failed("could not create context")
            return
        }

        model = loaded
        context = ctx
        vocab = llama_model_get_vocab(loaded)
        sampler = makeSampler()
        loadedPath = path
        cachedTokens = []
        currentStatus = .ready
    }

    /// Releases the model *and* the ggml backend.
    ///
    /// Must happen before the process exits. ggml registers an `atexit` handler
    /// that frees the Metal device and asserts if resource sets are still alive,
    /// which aborts the app on every quit (`ggml_metal_rsets_free` ->
    /// `ggml_abort`). Tearing down first leaves it nothing to complain about.
    func shutdown() {
        unload()
        llama_backend_free()
    }

    func unload() {
        if let sampler { llama_sampler_free(sampler); self.sampler = nil }
        if let context { llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        loadedPath = nil
        cachedTokens = []
        currentStatus = .noModelSelected
    }

    func warmUp() async {
        guard currentStatus.isReady, context != nil else { return }
        // Decoding a single token forces Metal pipeline setup, so the first real
        // keystroke does not pay for it.
        _ = generate(prompt: "The", maxTokens: 1, maxWords: 1)
        cachedTokens = []
    }

    // MARK: - Completion

    func complete(_ request: CompletionRequest) async -> String? {
        guard currentStatus.isReady, context != nil, vocab != nil else { return nil }
        guard request.hasEnoughContext else { return nil }

        updateBias(vocabulary: request.vocabulary, strength: request.wordChoiceStrength)

        let started = Date()
        let raw = generate(prompt: CompletionPrompt.text(for: request), maxTokens: request.tokenBudget, maxWords: request.maxWords)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        Log.core.notice("llama \(elapsed, privacy: .public)ms reuse=\(self.lastPrefixReuse, privacy: .public)/\(self.lastPromptTokens, privacy: .public)")
        guard !Task.isCancelled, let raw, !raw.isEmpty else { return nil }

        return CompletionSanitizer.sanitize(
            raw,
            before: request.before,
            needsLeadingSpace: request.needsLeadingSpace
        )
    }

    // MARK: - Generation

    private func generate(prompt: String, maxTokens: Int, maxWords: Int) -> String? {
        guard let context, let vocab, let sampler else { return nil }

        // Always, not only when the cache is empty. What is tokenized here is
        // the *whole* prompt on every call, never a delta, so a BOS the model
        // asks for belongs at the head of every one of them. Adding it once and
        // omitting it thereafter cost twice over: request two compared a prompt
        // with no BOS against a cached array beginning with one, shared nothing,
        // and re-decoded in full — and every prompt from then on ran without the
        // token the model was trained to open on.
        var tokens = tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { return nil }

        // Never let the prompt crowd out room to generate.
        //
        // Trimmed in fixed blocks rather than to an exact fit. A window sized to
        // the prompt slides by a token per keystroke, which moves the *start* of
        // the prompt every time — and the start is what the cache matches on, so
        // once a session filled the context, reuse fell to nothing and every
        // pass re-decoded some two thousand tokens. Dropping a block at a time
        // holds the start still for a hundred-odd keystrokes: one full re-decode
        // per block instead of one per keystroke.
        //
        // The head is kept where there is one, since a plain suffix drops the
        // BOS just added, on exactly the prompts least able to afford it.
        let limit = Int(contextLength) - maxTokens - 8
        if tokens.count > limit {
            let head: [llama_token] = tokens.first == llama_vocab_bos(vocab) ? [tokens[0]] : []
            let body = tokens.dropFirst(head.count)
            let excess = body.count - (limit - head.count)
            let dropped = min(body.count, ((excess + trimBlock - 1) / trimBlock) * trimBlock)
            tokens = head + body.dropFirst(dropped)
        }

        // Reuse whatever prefix already sits in the KV cache.
        let shared = sharedPrefixLength(cachedTokens, tokens)
        lastPrefixReuse = shared
        lastPromptTokens = tokens.count
        lastPromptBeganWithBOS = tokens.first == llama_vocab_bos(vocab)
        if let memory = llama_get_memory(context) {
            llama_memory_seq_rm(memory, 0, llama_pos(shared), -1)
        }

        var pending = Array(tokens[shared...])
        if pending.isEmpty {
            // Identical prompt: step back one token so there are logits to
            // sample from.
            guard shared > 0 else { return nil }
            if let memory = llama_get_memory(context) {
                llama_memory_seq_rm(memory, 0, llama_pos(shared - 1), -1)
            }
            pending = [tokens[shared - 1]]
        }

        // Fed in `n_batch`-sized pieces. `llama_decode` does not return an
        // error when handed more than the context was built for — it fails
        // `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` and calls `ggml_abort`,
        // taking the process with it. One decode of the whole diverging suffix
        // was therefore a crash waiting for a cold cache and a full prompt, and
        // a full prompt is not exotic: `before` alone runs to 1,200 characters,
        // and a mail reply adds the quoted thread, the screen text and the
        // clipboard on top. Around 800 tokens, against a ceiling of 512.
        var cursor = 0
        while cursor < pending.count {
            let end = min(cursor + Int(batchSize), pending.count)
            var chunk = Array(pending[cursor..<end])
            guard chunk.withUnsafeMutableBufferPointer({ buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))) == 0
            }) else {
                cachedTokens = []
                return nil
            }
            cursor = end
        }

        // The penalty sampler carries state between calls; without this the
        // previous suggestion suppresses words in the next one.
        llama_sampler_reset(sampler)

        var output: [UInt8] = []
        var generated: [llama_token] = []
        var produced = 0

        while produced < maxTokens {
            let next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, next) { break }

            let bytes = pieceBytes(next)
            // One line only; a newline ends the suggestion.
            if let newline = bytes.firstIndex(of: 0x0A) {
                output.append(contentsOf: bytes[..<newline])
                break
            }
            output.append(contentsOf: bytes)

            // Stop on word count, not token count. Tokens are a poor proxy:
            // a 12-token budget yielded 9-11 words, so "~4 words" never meant
            // four. Spaces in the continuation track words directly.
            if output.filter({ $0 == 0x20 }).count > maxWords { break }

            llama_sampler_accept(sampler, next)
            generated.append(next)
            produced += 1

            // Safety net: a repetition penalty alone does not always break a
            // peaked greedy distribution ("of the the the the…" survived at
            // 1.15). Stop on any short cycle repeated three times, whatever the
            // model.
            if isDegenerate(generated) {
                degenerateStops += 1
                break
            }

            var single = [next]
            guard single.withUnsafeMutableBufferPointer({ buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1)) == 0
            }) else {
                // A failed decode leaves the cache in a state this array cannot
                // describe, so stop describing it. Rebuilding from scratch next
                // time is the same answer the prompt decode above gives.
                decodeFailures += 1
                cachedTokens = []
                return String(decoding: output, as: UTF8.self)
            }
            // Appended only now. `tokens` is the record of what the cache holds,
            // and appending before the decode left the record one ahead of the
            // truth on both breaks above — `isDegenerate` among them, which is
            // the loop-breaker and so fires often. The next request would then
            // trim to a prefix the cache never had and decode its suffix against
            // a context silently one token short.
            tokens.append(next)

            if Task.isCancelled { break }
        }

        cachedTokens = tokens
        return String(decoding: output, as: UTF8.self)
    }

    /// True when the tail is a cycle of length 1-3 repeated three times.
    private func isDegenerate(_ tokens: [llama_token]) -> Bool {
        for cycle in 1...3 where tokens.count >= cycle * 3 {
            let tail = tokens.suffix(cycle * 3)
            let first = Array(tail.prefix(cycle))
            if tail.elementsEqual(first + first + first) { return true }
        }
        return false
    }

    private func sharedPrefixLength(_ lhs: [llama_token], _ rhs: [llama_token]) -> Int {
        var index = 0
        while index < lhs.count, index < rhs.count, lhs[index] == rhs[index] { index += 1 }
        return index
    }

    // MARK: - Tokens

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 8)

        let written = text.withCString { pointer in
            llama_tokenize(vocab, pointer, byteCount, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard written >= 0 else { return [] }
        return Array(tokens.prefix(Int(written)))
    }

    /// Returns raw bytes rather than a String: a multi-byte character can be
    /// split across two tokens, so decoding must happen once at the end.
    private func pieceBytes(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buffer = [CChar](repeating: 0, count: 64)
        var written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if written < 0 {
            buffer = [CChar](repeating: 0, count: Int(-written))
            written = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard written > 0 else { return [] }
        return buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Sampling

    /// Rebuilds the sampler when the learned vocabulary or the slider changes.
    ///
    /// Each learned term is biased on its *first* token, prefixed with a space
    /// because a continuation starts at a word boundary. Frequency is damped
    /// logarithmically so one very common term cannot dominate.
    private func updateBias(vocabulary: [String: Int], strength: Double) {
        guard strength > 0.01, !vocabulary.isEmpty else {
            if !biasSignature.isEmpty {
                if let sampler { llama_sampler_free(sampler) }
                sampler = makeSampler()
                biasSignature = ""
            }
            return
        }

        // Over the whole set, counts included. The previous key was the strength,
        // the term *count*, and the first eight terms alphabetically — so a
        // vocabulary that grew and shrank back, or whose counts moved without its
        // membership changing, went unnoticed. Counts are not incidental here:
        // the weight below is derived from them.
        var hasher = Hasher()
        hasher.combine(strength)
        for term in vocabulary.keys.sorted() {
            hasher.combine(term)
            hasher.combine(vocabulary[term] ?? 0)
        }
        let signature = String(hasher.finalize())
        guard signature != biasSignature else { return }

        // Bias only the *word-initial* token of a term, weighted by how
        // specific it is.
        //
        // Two earlier approaches both failed in characteristic ways. Biasing the
        // first token with a flat weight boosts bare prefixes: " Zephyrine"
        // tokenizes as [" Z", "eph", …], and the model emitted "Quaternions" and
        // "Zeta". Biasing *every* token is worse — raising interior pieces out of
        // context fabricates non-words, observed live as " take the tiffle t".
        //
        // Weighting by length means a distinctive opening like " Kub" pulls hard
        // while a bare " Z" is ignored, and interior tokens are left alone so a
        // word can only be reached the normal way.
        var weights: [llama_token: Double] = [:]
        for (term, count) in vocabulary {
            let tokens = tokenize(" " + term, addSpecial: false)
            guard let first = tokens.first else { continue }

            let piece = pieceBytes(first).count
            // Below three characters the token is a shared prefix, not a word.
            let specificity = min(1.0, Double(max(0, piece - 2)) / 3.0)
            guard specificity > 0 else { continue }

            // Logits span a wide range and greedy decoding is decisive, so a
            // 1-3 point nudge is invisible. Frequency is damped logarithmically.
            let base = 6.0 + 2.0 * log(Double(max(1, count)))
            weights[first] = Swift.max(weights[first] ?? 0, strength * base * specificity)
        }

        let entries = weights
            .filter { $0.value > 0.1 }
            .map { llama_logit_bias(token: $0.key, bias: Float($0.value)) }

        // Rebuilt even when nothing survived the filter — every term tokenized
        // to a bare prefix — because that state *is* "no bias", the same as the
        // slider at zero, and it has to be applied rather than returned from.
        // Returning early left the previous chain in place while the signature
        // said otherwise, which pinned a stale bias there for the rest of the
        // session. The signature is recorded last, after the swap it describes.
        if let sampler { llama_sampler_free(sampler) }
        sampler = makeSampler(bias: entries)
        biasSignature = signature
    }

    /// Greedy **with a repetition penalty**.
    ///
    /// Greedy alone keeps the same prefix yielding the same suggestion, which
    /// matters under a caret — a suggestion that flickers between renders is
    /// worse than none. But pure greedy decoding on a small model collapses into
    /// loops: measured on Gemma 3 1B, "the meeting" produced
    /// "was scheduled to be held to be held to be held…". The penalty applies
    /// only to tokens this generation emitted (prompt tokens are never
    /// `accept`ed), so the user's own repeated words are untouched.
    ///
    /// `bias` is the hook for the "Personalize word choice" slider: learned terms
    /// get a positive bias so the model leans toward the user's own vocabulary.
    private func makeSampler(bias: [llama_logit_bias] = []) -> UnsafeMutablePointer<llama_sampler>? {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        guard let chain, let vocab else { return nil }

        if !bias.isEmpty {
            var entries = bias
            llama_sampler_chain_add(chain, llama_sampler_init_logit_bias(
                llama_vocab_n_tokens(vocab),
                Int32(entries.count),
                &entries
            ))
        }

        llama_sampler_chain_add(chain, llama_sampler_init_penalties(
            llama_vocab_n_tokens(vocab),
            64,     // window of recently generated tokens
            1.25,   // repeat penalty; mild enough that natural phrasing survives
            0.0,    // frequency penalty off
            0.0     // presence penalty off
        ))
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        return chain
    }
}
