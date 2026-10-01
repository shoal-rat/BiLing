import Accelerate
import CLlama
import Foundation
import ZhiyinCore

/// 子期 · The listener.
///
/// 钟子期 understood what 伯牙 meant from the sound of his qin alone. This is
/// the fine-tuned model that does the same for keys: it reads the text before
/// the caret and the raw keys, and writes what you mean.
///
/// Decoding is a constrained beam search. Only tokens the keys can spell are
/// ever considered (CharTrie.walk with the three rules of 弦), so the model
/// cannot invent text you did not type — it can only choose. The search is
/// token-synchronous: every live hypothesis has the same length, which lets
/// all of them run as one batch of single-token sequences that share the
/// prompt's KV cells.
///
/// Not thread-safe: own it from one serial queue (see ListenerService).
public final class Ziqi {
    public struct Config: Sendable {
        public var beam = 6
        public var results = 8
        /// Score bonus per character read, so a hypothesis that has read more
        /// of the keys is not ranked down for having already paid for it.
        public var charReward: Float = 1.0
        /// Extra cost of a Latin token (keeps pinyin from turning into English).
        public var latinPenalty: Float = 2.5
        public var contextScalars = 48
        public var gpuLayers: Int32 = -1
        public init() {}
    }

    public struct Result: Sendable, Hashable {
        public let text: String
        public let logp: Float
        public let tokens: [Int32]
    }

    /// A first token the model considered, ranked in context: these become
    /// the "pick part of the input" candidates.
    public struct Lead: Sendable, Hashable {
        public let text: String
        public let end: Int
        public let logp: Float
    }

    public struct Answer: Sendable {
        public let context: String
        public let keys: String
        public let results: [Result]
        public let leads: [Lead]
        public let milliseconds: Double
        public let steps: Int
        public let promptTokens: Int
        public let decodedPromptTokens: Int
        /// Time spent inside llama_decode (GPU), the rest is search bookkeeping.
        public let decodeMilliseconds: Double
    }

    public enum LoadError: Error, CustomStringConvertible {
        case model(String), context, vocabulary(String)
        public var description: String {
            switch self {
            case .model(let p): return "子期 could not load the model at \(p)"
            case .context: return "子期 could not create an inference context"
            case .vocabulary(let why): return "子期's vocabulary table is unusable: \(why)"
            }
        }
    }

    // Prompt layout — must match Tools/zhuoqin/fmt.py byte for byte.
    static let keysMarker: llama_token = 151659 // <|fim_prefix|>
    static let outMarker: llama_token = 151660 // <|fim_middle|>
    static let letterBase: llama_token = 64 // 'a'
    static let apostropheToken: llama_token = 6

    public var config: Config
    public let description: String
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let trie: CharTrie
    private let vocabularySize: Int
    private var batch: llama_batch
    private let batchCapacity: Int32 = 512
    private let maxSequences: Int32

    private var cachedPrompt: [llama_token] = []
    private var cachedLogits: [Float] = []
    private var pieces: [llama_token: String] = [:]
    private var scratch: [Float]

    public init(modelPath: String, vocabularyPath: String, config: Config = Config()) throws {
        self.config = config
        trie = try CharTrie(path: vocabularyPath)
        guard trie.kind == .tokens else { throw LoadError.vocabulary("not a token trie") }

        Ziqi.backendOnce
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = config.gpuLayers
        modelParams.use_mmap = true
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LoadError.model(modelPath)
        }
        maxSequences = Int32(config.beam + 1)
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = UInt32(batchCapacity)
        contextParams.n_ubatch = UInt32(batchCapacity)
        contextParams.n_seq_max = UInt32(maxSequences)
        contextParams.n_threads = 4
        contextParams.n_threads_batch = 4
        contextParams.kv_unified = true
        contextParams.offload_kqv = true
        contextParams.no_perf = true
        contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LoadError.context
        }
        self.model = model
        self.ctx = context
        vocab = llama_model_get_vocab(model)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))
        scratch = [Float](repeating: 0, count: vocabularySize)
        batch = llama_batch_init(batchCapacity, 0, 1)

        var buffer = [CChar](repeating: 0, count: 160)
        llama_model_desc(model, &buffer, buffer.count)
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let megabytes = Double(llama_model_size(model)) / 1_048_576
        description = "\(name) · \(Int(megabytes)) MB"
    }

    deinit {
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    private static let backendOnce: Void = {
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text else { return }
            FileHandle.standardError.write(Data(("子期: " + String(cString: text)).utf8))
        }, nil)
        llama_backend_init()
    }()

    public var syllables: SyllableTable { trie.syllables }

    // MARK: - Prompt

    func tokenize(_ text: String) -> [llama_token] {
        guard !text.isEmpty else { return [] }
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = utf8.withUnsafeBufferPointer { raw in
            raw.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), false, false)
            }
        }
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = utf8.withUnsafeBufferPointer { raw in
                raw.withMemoryRebound(to: CChar.self) {
                    llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), false, false)
                }
            }
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    func prompt(context: String, keys: [UInt8]) -> [llama_token] {
        let scalars = context.unicodeScalars
        let clipped = scalars.count > config.contextScalars
            ? String(String.UnicodeScalarView(scalars.suffix(config.contextScalars)))
            : context
        var tokens = tokenize(clipped)
        tokens.append(Ziqi.keysMarker)
        for k in keys {
            tokens.append(k == KeyReader.apostrophe ? Ziqi.apostropheToken : Ziqi.letterBase + llama_token(k) - 97)
        }
        tokens.append(Ziqi.outMarker)
        return tokens
    }

    func piece(_ token: llama_token) -> String {
        if let cached = pieces[token] { return cached }
        var buffer = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        let text = n > 0
            ? String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        pieces[token] = text
        return text
    }

    // MARK: - KV cache for the prompt (sequence 0)

    /// Makes sequence 0 hold exactly `prompt` and leaves the next-token
    /// logits after it in `cachedLogits`. Only the divergent suffix is decoded:
    /// a keystroke adds two tokens (the key and the output marker).
    private func refreshPrompt(_ prompt: [llama_token]) -> Int? {
        let memory = llama_get_memory(ctx)
        var common = 0
        let limit = min(prompt.count, cachedPrompt.count)
        while common < limit, prompt[common] == cachedPrompt[common] { common += 1 }
        if common == prompt.count, common == cachedPrompt.count, !cachedLogits.isEmpty {
            return 0
        }
        let start = min(common, prompt.count - 1)
        llama_memory_seq_rm(memory, 0, llama_pos(start), -1)
        var position = start
        while position < prompt.count {
            let chunk = min(Int(batchCapacity), prompt.count - position)
            batch.n_tokens = Int32(chunk)
            for i in 0..<chunk {
                batch.token[i] = prompt[position + i]
                batch.pos[i] = llama_pos(position + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = (position + i == prompt.count - 1) ? 1 : 0
            }
            if llama_decode(ctx, batch) != 0 {
                cachedPrompt = []
                cachedLogits = []
                llama_memory_clear(memory, true)
                return nil
            }
            position += chunk
        }
        guard let logits = llama_get_logits_ith(ctx, -1) else { return nil }
        cachedLogits = Array(UnsafeBufferPointer(start: logits, count: vocabularySize))
        cachedPrompt = prompt
        return prompt.count - start
    }

    /// log Σ exp(row), vectorised.
    private func logSumExp(_ row: UnsafePointer<Float>) -> Float {
        var maximum: Float = 0
        vDSP_maxv(row, 1, &maximum, vDSP_Length(vocabularySize))
        var negative = -maximum
        var sum: Float = 0
        scratch.withUnsafeMutableBufferPointer { buf in
            vDSP_vsadd(row, 1, &negative, buf.baseAddress!, 1, vDSP_Length(vocabularySize))
            var n = Int32(vocabularySize)
            vvexpf(buf.baseAddress!, buf.baseAddress!, &n)
            vDSP_sve(buf.baseAddress!, 1, &sum, vDSP_Length(vocabularySize))
        }
        return maximum + log(sum)
    }

    // MARK: - Search

    struct Option {
        let token: llama_token
        let end: Int
        let chars: Int
        let latin: Bool
    }

    struct Hypothesis {
        var tokens: [llama_token]
        var position: Int
        var logp: Float
        var chars: Int
        var sequence: Int32
        var row: Int32
    }

    private func options(_ reader: KeyReader, at p: Int, cache: inout [Int: [Option]]) -> [Option] {
        if let hit = cache[p] { return hit }
        var out: [Option] = []
        for m in trie.walk(reader, from: p, maxChars: 4) {
            out.append(Option(token: llama_token(trie.payload(Int(m.entry))), end: Int(m.end), chars: Int(m.chars), latin: false))
        }
        for (token, end) in trie.latinMatches(reader, from: p) {
            out.append(Option(token: llama_token(token), end: end, chars: max(1, (end - p) / 3), latin: true))
        }
        cache[p] = out
        return out
    }

    /// Reads `keys` in the light of `context`. Returns nil when cancelled
    /// (checked between decode steps) or on a decode failure.
    public func listen(context: String, keys: String, isCancelled: () -> Bool = { false }) -> Answer? {
        let started = DispatchTime.now()
        let keyBytes = Array(keys.utf8)
        guard !keyBytes.isEmpty,
              keyBytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == KeyReader.apostrophe }) else { return nil }
        let reader = KeyReader(keyBytes, syllables: trie.syllables)
        let promptTokens = prompt(context: context, keys: keyBytes)
        guard promptTokens.count < 1200 else { return nil }
        var decodeNanos: UInt64 = 0
        let promptStarted = DispatchTime.now().uptimeNanoseconds
        guard let decodedPrompt = refreshPrompt(promptTokens) else { return nil }
        decodeNanos += DispatchTime.now().uptimeNanoseconds - promptStarted

        let memory = llama_get_memory(ctx)
        for s in 1..<maxSequences { llama_memory_seq_rm(memory, s, -1, -1) }

        let n = keyBytes.count
        let beam = config.beam
        var live = [Hypothesis(tokens: [], position: 0, logp: 0, chars: 0, sequence: 0, row: -1)]
        var finished: [String: Result] = [:]
        var leads: [Lead] = []
        var optionCache: [Int: [Option]] = [:]
        var freeSequences = Array((1..<maxSequences).reversed())
        var steps = 0

        for step in 0..<(n + 2) {
            if isCancelled() { return nil }
            struct Expansion { let score: Float; let rank: Float; let option: Option; let parent: Int }
            var expansions: [Expansion] = []
            for (index, h) in live.enumerated() {
                let opts = options(reader, at: h.position, cache: &optionCache)
                guard !opts.isEmpty else { continue }
                func expand(_ row: UnsafePointer<Float>) {
                    let normaliser = logSumExp(row)
                    for o in opts {
                        let score = h.logp + row[Int(o.token)] - normaliser - (o.latin ? config.latinPenalty : 0)
                        let chars = h.chars + o.chars
                        expansions.append(Expansion(
                            score: score, rank: score + config.charReward * Float(chars), option: o, parent: index
                        ))
                        if step == 0 {
                            leads.append(Lead(text: piece(o.token), end: o.end, logp: score))
                        }
                    }
                }
                if h.row < 0 {
                    cachedLogits.withUnsafeBufferPointer { expand($0.baseAddress!) }
                } else {
                    guard let p = llama_get_logits_ith(ctx, h.row) else { return nil }
                    expand(UnsafePointer(p))
                }
            }
            if expansions.isEmpty { break }
            expansions.sort { $0.rank > $1.rank }

            var bestFinal = finished.values.map(\.logp).max() ?? -.infinity
            var next: [(parent: Int, option: Option, score: Float)] = []
            for e in expansions {
                if e.option.end == n {
                    let tokens = live[e.parent].tokens + [e.option.token]
                    let text = tokens.map(piece).joined()
                    if finished[text].map({ $0.logp < e.score }) ?? true {
                        finished[text] = Result(text: text, logp: e.score, tokens: tokens.map { Int32($0) })
                        bestFinal = max(bestFinal, e.score)
                    }
                    continue
                }
                if next.count < beam, e.score > bestFinal - 12 {
                    next.append((e.parent, e.option, e.score))
                }
                if next.count >= beam, finished.count >= config.results { break }
            }
            if next.isEmpty { break }
            if !finished.isEmpty, finished.count >= 3, next.allSatisfy({ $0.score < bestFinal - 6 }) { break }

            // Re-assign KV sequences: dead parents release theirs; the first
            // child inherits its parent's; siblings get copies.
            var childCount = [Int](repeating: 0, count: live.count)
            for c in next { childCount[c.parent] += 1 }
            for (i, h) in live.enumerated() where childCount[i] == 0 && h.sequence != 0 {
                llama_memory_seq_rm(memory, h.sequence, -1, -1)
                freeSequences.append(h.sequence)
            }
            var inherited = [Bool](repeating: false, count: live.count)
            var children: [Hypothesis] = []
            for c in next {
                let parent = live[c.parent]
                var sequence: Int32
                if parent.sequence != 0, !inherited[c.parent] {
                    inherited[c.parent] = true
                    sequence = parent.sequence
                } else {
                    guard let fresh = freeSequences.popLast() else { continue }
                    sequence = fresh
                    llama_memory_seq_cp(memory, parent.sequence, sequence, -1, -1)
                }
                children.append(Hypothesis(
                    tokens: parent.tokens + [c.option.token],
                    position: c.option.end,
                    logp: c.score,
                    chars: parent.chars + c.option.chars,
                    sequence: sequence,
                    row: Int32(children.count)
                ))
            }
            // A sequence whose inheritor was skipped above must not leak: any
            // parent sequence not inherited and not 0 is released.
            for (i, h) in live.enumerated() where childCount[i] > 0 && !inherited[i] && h.sequence != 0 {
                llama_memory_seq_rm(memory, h.sequence, -1, -1)
                freeSequences.append(h.sequence)
            }

            batch.n_tokens = Int32(children.count)
            let position = llama_pos(promptTokens.count + step)
            for (i, child) in children.enumerated() {
                batch.token[i] = child.tokens.last!
                batch.pos[i] = position
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = child.sequence
                batch.logits[i] = 1
            }
            if isCancelled() { return nil }
            let decodeStarted = DispatchTime.now().uptimeNanoseconds
            let status = llama_decode(ctx, batch)
            // Logits are read on the CPU right after; wait for them here so the
            // timing attributes GPU time to decoding.
            llama_synchronize(ctx)
            decodeNanos += DispatchTime.now().uptimeNanoseconds - decodeStarted
            guard status == 0 else {
                for s in 1..<maxSequences { llama_memory_seq_rm(memory, s, -1, -1) }
                return nil
            }
            steps += 1
            live = children
        }

        for s in 1..<maxSequences { llama_memory_seq_rm(memory, s, -1, -1) }
        let results = finished.values.sorted { $0.logp > $1.logp }.prefix(config.results)
        var seenLeads = Set<String>()
        let rankedLeads = leads.sorted { $0.logp > $1.logp }.filter { seenLeads.insert($0.text + "\u{1}\($0.end)").inserted }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        return Answer(
            context: context,
            keys: keys,
            results: Array(results),
            leads: Array(rankedLeads.prefix(40)),
            milliseconds: elapsed,
            steps: steps,
            promptTokens: promptTokens.count,
            decodedPromptTokens: decodedPrompt,
            decodeMilliseconds: Double(decodeNanos) / 1e6
        )
    }

    /// Forget the cached prompt (e.g. after the context changed wholesale).
    public func reset() {
        cachedPrompt = []
        cachedLogits = []
        llama_memory_clear(llama_get_memory(ctx), true)
    }
}
