import Accelerate
import CLlama
import Foundation
import ZhiyinCore

/// 子期 · The listener.
///
/// 钟子期 understood what 伯牙 meant from the sound of his qin alone. 子期
/// listens to keys with two ears over one base model (Qwen3-0.6B):
///
/// * **听音** (tingyin) — the base model with a LoRA adapter trained to read
///   raw keys. It sees `[context] <keys> k e y s <out>` and knows which
///   letters it has read, which are initials, where the user is mid-syllable.
/// * **知意** (zhiyi) — the plain base model. It never sees the keys; it only
///   knows what reads as natural Chinese after the context. Fine-tuning blunts
///   that knowledge, so it is kept whole in a second context.
///
/// Every candidate token is scored by both ears — a product of experts — and
/// priced by a typing channel (reading a character by its initial, or through
/// a slip of the finger, costs a little). Only tokens the keys can spell are
/// ever considered (CharTrie.walk with the rules of 弦), so 子期 can only
/// choose, never invent.
///
/// The search is token-synchronous: every live hypothesis has the same
/// number of output tokens, so all of them go to the GPU as one batch of
/// single-token sequences sharing the prompt's KV cells. A keystroke appends
/// one key token to 听音's prompt; 知意's prompt does not change at all.
///
/// Not thread-safe: own it from one serial queue (see ListenerService).
public final class Ziqi {
    public struct Config: Sendable {
        public var beam = 10
        public var results = 8
        /// Weight of each ear's log-probability.
        public var tingWeight: Float = 1.0
        public var zhiWeight: Float = 0.6
        /// Partial hypotheses are ranked by score + perKey × keys read, so one
        /// that has read more of the keys is not ranked down for having paid.
        public var perKey: Float = 1.0
        /// Typing channel: cost of a character read by initial or prefix…
        public var abbreviationCost: Float = 1.0
        /// …and of a character read through a slip (走音: neighbour key,
        /// swapped, missing or doubled letter).
        public var slipCost: Float = 5.0
        /// Cost of a Latin token (keeps pinyin from turning into English).
        public var latinCost: Float = 3.0
        public var contextScalars = 48
        public var gpuLayers: Int32 = -1
        public init() {}

        /// Settings for the 知意 ear alone (no adapter): without the keys in
        /// view, abbreviations must cost more and the search must be wider.
        public static var zhiOnly: Config {
            var c = Config()
            c.tingWeight = 0
            c.zhiWeight = 1
            c.perKey = 1.2
            c.abbreviationCost = 2.5
            c.beam = 12
            return c
        }
    }

    public struct Result: Sendable, Hashable {
        public let text: String
        public let logp: Float
        public let tokens: [Int32]
    }

    /// A first token considered, ranked in context: these become the
    /// "pick part of the input" candidates.
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
        /// Time inside llama_decode (GPU); the rest is search bookkeeping.
        public let decodeMilliseconds: Double
    }

    public enum LoadError: Error, CustomStringConvertible {
        case model(String), adapter(String), context, vocabulary(String)
        public var description: String {
            switch self {
            case .model(let p): return "子期 could not load the model at \(p)"
            case .adapter(let p): return "子期 could not load the 听音 adapter at \(p)"
            case .context: return "子期 could not create an inference context"
            case .vocabulary(let why): return "子期's vocabulary table is unusable: \(why)"
            }
        }
    }

    // Prompt layout — must match Tools/zhuoqin/fmt.py byte for byte.
    static let keysMarker: llama_token = 151659 // <|fim_prefix|>
    static let outMarker: llama_token = 151660 // <|fim_middle|>
    static let endOfText: llama_token = 151643 // <|endoftext|>
    static let letterBase: llama_token = 64 // 'a'
    static let apostropheToken: llama_token = 6

    static let sequentialEars = ProcessInfo.processInfo.environment["ZHIYIN_SEQUENTIAL"] != nil
    static let trace = ProcessInfo.processInfo.environment["ZHIYIN_TRACE"] != nil
    public var config: Config
    public let description: String
    public let hasTingyin: Bool
    private let model: OpaquePointer
    private let vocab: OpaquePointer
    private let trie: CharTrie
    private let vocabularySize: Int
    private let maxSequences: Int32
    private var ting: Ear?
    private var zhi: Ear?
    private var pieces: [llama_token: String] = [:]

    /// One context over the shared model, with its prompt cached in
    /// sequence 0 and candidate hypotheses in sequences 1…beam.
    final class Ear {
        let ctx: OpaquePointer
        var batch: llama_batch
        let capacity: Int32 = 512
        var cachedPrompt: [llama_token] = []
        var cachedLogits: [Float] = []
        var scratch: [Float]
        let vocabularySize: Int

        init(ctx: OpaquePointer, vocabularySize: Int) {
            self.ctx = ctx
            self.vocabularySize = vocabularySize
            batch = llama_batch_init(capacity, 0, 1)
            scratch = [Float](repeating: 0, count: vocabularySize)
        }

        deinit {
            llama_batch_free(batch)
            llama_free(ctx)
        }

        var memory: llama_memory_t { llama_get_memory(ctx) }

        /// Makes sequence 0 hold exactly `prompt`, leaving the next-token
        /// logits in `cachedLogits`. Returns how many tokens were decoded.
        func refresh(_ prompt: [llama_token]) -> Int? {
            var common = 0
            let limit = min(prompt.count, cachedPrompt.count)
            while common < limit, prompt[common] == cachedPrompt[common] { common += 1 }
            if common == prompt.count, common == cachedPrompt.count, !cachedLogits.isEmpty { return 0 }
            let start = min(common, prompt.count - 1)
            llama_memory_seq_rm(memory, 0, llama_pos(start), -1)
            var position = start
            while position < prompt.count {
                let chunk = min(Int(capacity), prompt.count - position)
                batch.n_tokens = Int32(chunk)
                for i in 0..<chunk {
                    batch.token[i] = prompt[position + i]
                    batch.pos[i] = llama_pos(position + i)
                    batch.n_seq_id[i] = 1
                    batch.seq_id[i]![0] = 0
                    batch.logits[i] = (position + i == prompt.count - 1) ? 1 : 0
                }
                let t = DispatchTime.now().uptimeNanoseconds
                if llama_decode(ctx, batch) != 0 {
                    reset()
                    return nil
                }
                if Ziqi.trace {
                    llama_synchronize(ctx)
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
                    FileHandle.standardError.write(Data("trace \(name) prompt n=\(chunk) \(String(format: "%.2f", ms)) ms\n".utf8))
                }
                position += chunk
            }
            guard let logits = llama_get_logits_ith(ctx, -1) else { return nil }
            cachedLogits = Array(UnsafeBufferPointer(start: logits, count: vocabularySize))
            cachedPrompt = prompt
            return prompt.count - start
        }

        func clearCandidates(_ maxSequences: Int32) {
            for s in 1..<maxSequences { llama_memory_seq_rm(memory, s, -1, -1) }
        }

        func reset() {
            cachedPrompt = []
            cachedLogits = []
            llama_memory_clear(memory, true)
        }

        /// Decodes one token per child, (token, sequence), at `position`.
        /// Pad every step to this many rows, so the decode graph keeps one
        /// shape and llama.cpp can reuse it instead of rebuilding per step.
        var name = "ear"
        var padTo = 0
        /// Sequence ids reserved for padding rows (one each, position 0).
        var padSequences: [Int32] = []

        func step(_ children: [(llama_token, Int32)], position: llama_pos) -> Bool {
            let pad = max(0, min(padTo, padSequences.count + children.count) - children.count)
            batch.n_tokens = Int32(children.count + pad)
            for (i, child) in children.enumerated() {
                batch.token[i] = child.0
                batch.pos[i] = position
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = child.1
                batch.logits[i] = 1
            }
            for k in 0..<pad {
                let i = children.count + k
                batch.token[i] = children.last?.0 ?? 0
                batch.pos[i] = 0
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = padSequences[k]
                batch.logits[i] = 1
            }
            let t = DispatchTime.now().uptimeNanoseconds
            let ok = llama_decode(ctx, batch) == 0
            llama_synchronize(ctx)
            if Ziqi.trace {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
                FileHandle.standardError.write(Data("trace \(name) step n=\(batch.n_tokens) \(String(format: "%.2f", ms)) ms\n".utf8))
            }
            for k in 0..<pad { llama_memory_seq_rm(memory, padSequences[k], -1, -1) }
            return ok
        }

        /// log Σ exp(row), vectorised.
        func logSumExp(_ row: UnsafePointer<Float>) -> Float {
            var maximum: Float = 0
            vDSP_maxv(row, 1, &maximum, vDSP_Length(vocabularySize))
            var negative = -maximum
            var sum: Float = 0
            let n = vocabularySize
            scratch.withUnsafeMutableBufferPointer { buf in
                vDSP_vsadd(row, 1, &negative, buf.baseAddress!, 1, vDSP_Length(n))
                var count = Int32(n)
                vvexpf(buf.baseAddress!, buf.baseAddress!, &count)
                vDSP_sve(buf.baseAddress!, 1, &sum, vDSP_Length(n))
            }
            return maximum + log(sum)
        }

        /// Calls `body` with a hypothesis's logit row (row < 0: the prompt's
        /// own next-token row) and its log-normaliser.
        func withRow(_ row: Int32, _ body: (UnsafePointer<Float>, Float) -> Void) -> Bool {
            if row < 0 {
                cachedLogits.withUnsafeBufferPointer { body($0.baseAddress!, logSumExp($0.baseAddress!)) }
                return true
            }
            guard let p = llama_get_logits_ith(ctx, row) else { return false }
            body(UnsafePointer(p), logSumExp(UnsafePointer(p)))
            return true
        }
    }

    public init(modelPath: String, adapterPath: String?, vocabularyPath: String, config: Config? = nil) throws {
        trie = try CharTrie(path: vocabularyPath)
        guard trie.kind == .tokens else { throw LoadError.vocabulary("not a token trie") }

        Ziqi.backendOnce
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = (config ?? Config()).gpuLayers
        modelParams.use_mmap = true
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LoadError.model(modelPath)
        }
        self.model = model
        vocab = llama_model_get_vocab(model)
        vocabularySize = Int(llama_vocab_n_tokens(vocab))

        var adapter: OpaquePointer?
        if let adapterPath, FileManager.default.fileExists(atPath: adapterPath) {
            adapter = llama_adapter_lora_init(model, adapterPath)
            if adapter == nil {
                llama_model_free(model)
                throw LoadError.adapter(adapterPath)
            }
        }
        hasTingyin = adapter != nil
        let chosen = config ?? (adapter != nil ? Config() : Config.zhiOnly)
        self.config = chosen
        maxSequences = Int32(max(chosen.beam, 12) + 1)
        let padding = ProcessInfo.processInfo.environment["ZHIYIN_PAD"] != nil ? chosen.beam : 0
        let sequences = maxSequences + Int32(padding)

        func makeContext() -> OpaquePointer? {
            var p = llama_context_default_params()
            p.n_ctx = UInt32(ProcessInfo.processInfo.environment["ZHIYIN_NCTX"].flatMap(Int.init) ?? 2048)
            p.n_batch = 512
            p.n_ubatch = 512
            p.n_seq_max = UInt32(sequences)
            p.n_threads = 4
            p.n_threads_batch = 4
            p.kv_unified = true
            p.offload_kqv = true
            p.no_perf = true
            p.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            return llama_init_from_model(model, p)
        }
        guard let zhiContext = makeContext() else {
            llama_model_free(model)
            throw LoadError.context
        }
        zhi = Ear(ctx: zhiContext, vocabularySize: vocabularySize)
        let firstPad = maxSequences
        let padSequences = (0..<padding).map { firstPad + Int32($0) }
        zhi?.name = "zhi"
        zhi?.padTo = padding
        zhi?.padSequences = padSequences
        if let adapter {
            guard let tingContext = makeContext() else {
                zhi = nil
                llama_model_free(model)
                throw LoadError.context
            }
            var adapters: [OpaquePointer?] = [adapter]
            var scales: [Float] = [1.0]
            _ = llama_set_adapters_lora(tingContext, &adapters, 1, &scales)
            ting = Ear(ctx: tingContext, vocabularySize: vocabularySize)
            ting?.name = "ting"
            ting?.padTo = padding
            ting?.padSequences = padSequences
        }

        var buffer = [CChar](repeating: 0, count: 160)
        llama_model_desc(model, &buffer, buffer.count)
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let megabytes = Double(llama_model_size(model)) / 1_048_576
        description = "\(name) · \(Int(megabytes)) MB · \(adapter != nil ? "听音+知意" : "知意")"
    }

    deinit {
        // Contexts first; the model (and its adapter) must outlive them.
        ting = nil
        zhi = nil
        llama_model_free(model)
    }

    private static let backendOnce: Void = {
        llama_log_set({ level, text, _ in
            // Errors only; CONT (continuation dots) ranks above ERROR numerically.
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            FileHandle.standardError.write(Data(("子期: " + String(cString: text)).utf8))
        }, nil)
        llama_backend_init()
    }()

    public var syllables: SyllableTable { trie.syllables }

    // MARK: - Prompts

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

    func clip(_ context: String) -> String {
        let scalars = context.unicodeScalars
        return scalars.count > config.contextScalars
            ? String(String.UnicodeScalarView(scalars.suffix(config.contextScalars)))
            : context
    }

    /// 听音's prompt: context, then every key as its own token.
    func tingPrompt(_ context: [llama_token], keys: [UInt8]) -> [llama_token] {
        var tokens = context
        tokens.append(Ziqi.keysMarker)
        for k in keys {
            tokens.append(k == KeyReader.apostrophe ? Ziqi.apostropheToken : Ziqi.letterBase + llama_token(k) - 97)
        }
        tokens.append(Ziqi.outMarker)
        return tokens
    }

    /// 知意's prompt: the context alone, after a document boundary.
    func zhiPrompt(_ context: [llama_token]) -> [llama_token] {
        [Ziqi.endOfText] + context
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

    // MARK: - Search

    struct Option {
        let token: llama_token
        let end: Int
        let cost: Float
        let slips: Int
    }

    struct Hypothesis {
        var tokens: [llama_token]
        var position: Int
        var logp: Float
        var slips: Int
        var sequence: Int32
        var row: Int32
    }

    private func options(_ reader: KeyReader, at p: Int, cache: inout [Int: [Option]]) -> [Option] {
        if let hit = cache[p] { return hit }
        var out: [Option] = []
        for m in trie.walk(reader, from: p, maxChars: 4) {
            out.append(Option(
                token: llama_token(trie.payload(Int(m.entry))),
                end: Int(m.end),
                cost: config.abbreviationCost * Float(m.abbreviated) + config.slipCost * Float(m.slips),
                slips: Int(m.slips)
            ))
        }
        for (token, end) in trie.latinMatches(reader, from: p) {
            out.append(Option(token: llama_token(token), end: end, cost: config.latinCost, slips: 0))
        }
        cache[p] = out
        return out
    }

    /// How `text` (BPE-tokenized) reads the keys: the cheapest channel cost
    /// over all alignments that end exactly at the end of the keys, or nil.
    private func alignment(_ tokens: [llama_token], _ reader: KeyReader, cache: inout [Int: [Option]]) -> Float? {
        var states: [Int: (cost: Float, slips: Int)] = [0: (0, 0)]
        for t in tokens {
            var next: [Int: (cost: Float, slips: Int)] = [:]
            for (p, st) in states {
                for o in options(reader, at: p, cache: &cache) where o.token == t {
                    let slips = st.slips + o.slips
                    guard slips <= KeyReader.maxSlips else { continue }
                    let c = st.cost + o.cost
                    if next[o.end].map({ c < $0.cost }) ?? true { next[o.end] = (c, slips) }
                }
            }
            if next.isEmpty { return nil }
            states = next
        }
        return states[reader.count]?.cost
    }

    /// Reads `keys` in the light of `context`. Returns nil when cancelled
    /// (checked between decode steps) or on a decode failure.
    ///
    /// `rescue` are readings found elsewhere (琴谱's sentences, 默契's
    /// memories). The beam can miss a name or an idiom the dictionary knows;
    /// these are scored by both ears exactly like the beam's own results, in
    /// one extra batched decode, and ranked together with them.
    public func listen(
        context: String,
        keys: String,
        rescue: [String] = [],
        isCancelled: () -> Bool = { false }
    ) -> Answer? {
        let started = DispatchTime.now()
        let keyBytes = Array(keys.utf8)
        guard !keyBytes.isEmpty,
              keyBytes.allSatisfy({ ($0 >= 97 && $0 <= 122) || $0 == KeyReader.apostrophe }) else { return nil }
        let reader = KeyReader(keyBytes, syllables: trie.syllables)
        let contextTokens = tokenize(clip(context))
        let ting = config.tingWeight > 0 ? self.ting : nil
        let zhi = (config.zhiWeight > 0 || ting == nil) ? self.zhi : nil
        let tingWeight = config.tingWeight
        let zhiWeight = ting == nil ? 1 : config.zhiWeight
        let tingTokens = tingPrompt(contextTokens, keys: keyBytes)
        let zhiTokens = zhiPrompt(contextTokens)
        let ears = [ting, zhi].compactMap { $0 }
        guard !ears.isEmpty else { return nil }

        var decodeNanos: UInt64 = 0
        var decodedPrompt = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        if let ting {
            guard let n = ting.refresh(tingTokens) else { return nil }
            decodedPrompt += n
        }
        if let zhi {
            guard let n = zhi.refresh(zhiTokens) else { return nil }
            decodedPrompt += n
        }
        for ear in ears { ear.clearCandidates(maxSequences) }
        decodeNanos += DispatchTime.now().uptimeNanoseconds - t0

        let n = keyBytes.count
        let beam = config.beam
        var live = [Hypothesis(tokens: [], position: 0, logp: 0, slips: 0, sequence: 0, row: -1)]
        var finished: [String: Result] = [:]
        var leads: [Lead] = []
        var optionCache: [Int: [Option]] = [:]
        var freeSequences = Array((1..<maxSequences).reversed())
        var steps = 0
        let maxSlips = KeyReader.maxSlips

        func release() { for ear in ears { ear.clearCandidates(maxSequences) } }

        for step in 0..<(n + 2) {
            if isCancelled() { release(); return nil }
            struct Expansion { let score: Float; let rank: Float; let option: Option; let parent: Int }
            var expansions: [Expansion] = []
            for (index, h) in live.enumerated() {
                let opts = options(reader, at: h.position, cache: &optionCache)
                guard !opts.isEmpty else { continue }
                var combined = [Float](repeating: 0, count: opts.count)
                if let ting {
                    let ok = ting.withRow(h.row) { row, z in
                        for (i, o) in opts.enumerated() { combined[i] += tingWeight * (row[Int(o.token)] - z) }
                    }
                    guard ok else { release(); return nil }
                }
                if let zhi {
                    let ok = zhi.withRow(h.row) { row, z in
                        for (i, o) in opts.enumerated() { combined[i] += zhiWeight * (row[Int(o.token)] - z) }
                    }
                    guard ok else { release(); return nil }
                }
                for (i, o) in opts.enumerated() where h.slips + o.slips <= maxSlips {
                    let score = h.logp + combined[i] - o.cost
                    expansions.append(Expansion(score: score, rank: score + config.perKey * Float(o.end), option: o, parent: index))
                    if step == 0 { leads.append(Lead(text: piece(o.token), end: o.end, logp: score)) }
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
                if next.count < beam { next.append((e.parent, e.option, e.score)) }
                if next.count >= beam, finished.count >= config.results { break }
            }
            if next.isEmpty { break }
            if !finished.isEmpty, next.allSatisfy({ $0.score < bestFinal - 8 }) { break }

            // Re-assign KV sequences, identically in every ear: dead parents
            // release theirs, the first child inherits its parent's, siblings
            // get copies.
            var childCount = [Int](repeating: 0, count: live.count)
            for c in next { childCount[c.parent] += 1 }
            for (i, h) in live.enumerated() where childCount[i] == 0 && h.sequence != 0 {
                for ear in ears { llama_memory_seq_rm(ear.memory, h.sequence, -1, -1) }
                freeSequences.append(h.sequence)
            }
            var inherited = [Bool](repeating: false, count: live.count)
            var children: [Hypothesis] = []
            for c in next {
                let parent = live[c.parent]
                let sequence: Int32
                if parent.sequence != 0, !inherited[c.parent] {
                    inherited[c.parent] = true
                    sequence = parent.sequence
                } else {
                    guard let fresh = freeSequences.popLast() else { continue }
                    sequence = fresh
                    for ear in ears { llama_memory_seq_cp(ear.memory, parent.sequence, sequence, -1, -1) }
                }
                children.append(Hypothesis(
                    tokens: parent.tokens + [c.option.token], position: c.option.end, logp: c.score,
                    slips: parent.slips + c.option.slips, sequence: sequence, row: Int32(children.count)
                ))
            }
            if isCancelled() { release(); return nil }
            let batch = children.map { ($0.tokens.last!, $0.sequence) }
            let decodeStarted = DispatchTime.now().uptimeNanoseconds
            var tingOK = true
            var zhiOK = true
            // The two ears are independent contexts: decode them side by side.
            if Ziqi.sequentialEars {
                if let ting { tingOK = ting.step(batch, position: llama_pos(tingTokens.count + step)) }
                if let zhi { zhiOK = zhi.step(batch, position: llama_pos(zhiTokens.count + step)) }
            } else {
                DispatchQueue.concurrentPerform(iterations: 2) { i in
                    if i == 0, let ting { tingOK = ting.step(batch, position: llama_pos(tingTokens.count + step)) }
                    if i == 1, let zhi { zhiOK = zhi.step(batch, position: llama_pos(zhiTokens.count + step)) }
                }
            }
            decodeNanos += DispatchTime.now().uptimeNanoseconds - decodeStarted
            guard tingOK, zhiOK else { release(); return nil }
            steps += 1
            live = children
        }

        // 琴谱补漏: force-score readings the beam did not reach.
        release()
        var plans: [(text: String, tokens: [llama_token], cost: Float)] = []
        var budget = 480
        for text in rescue where finished[text] == nil && !text.isEmpty {
            let tokens = tokenize(text)
            guard !tokens.isEmpty, tokens.count <= budget,
                  let cost = alignment(tokens, reader, cache: &optionCache) else { continue }
            plans.append((text, tokens, cost))
            budget -= tokens.count
            if plans.count >= min(6, Int(maxSequences) - 1) { break }
        }
        if !plans.isEmpty, !isCancelled() {
            // One batch: plan i occupies sequence i+1, positions after the prompt.
            var rows: [[Int32]] = []
            var batch: [(llama_token, Int32, llama_pos)] = []
            for (i, plan) in plans.enumerated() {
                let sequence = Int32(i + 1)
                for ear in ears { llama_memory_seq_cp(ear.memory, 0, sequence, -1, -1) }
                var r: [Int32] = []
                for (j, t) in plan.tokens.enumerated() {
                    r.append(Int32(batch.count))
                    batch.append((t, sequence, llama_pos(j)))
                }
                rows.append(r)
            }
            var scores = [Float](repeating: 0, count: plans.count)
            var ok = true
            for (ear, weight, promptCount) in [(ting, tingWeight, tingTokens.count), (zhi, zhiWeight, zhiTokens.count)] {
                guard let ear else { continue }
                ear.batch.n_tokens = Int32(batch.count)
                for (k, item) in batch.enumerated() {
                    ear.batch.token[k] = item.0
                    ear.batch.pos[k] = llama_pos(promptCount) + item.2
                    ear.batch.n_seq_id[k] = 1
                    ear.batch.seq_id[k]![0] = item.1
                    ear.batch.logits[k] = 1
                }
                let t1 = DispatchTime.now().uptimeNanoseconds
                guard llama_decode(ear.ctx, ear.batch) == 0 else { ok = false; break }
                llama_synchronize(ear.ctx)
                decodeNanos += DispatchTime.now().uptimeNanoseconds - t1
                for (i, plan) in plans.enumerated() {
                    for (j, t) in plan.tokens.enumerated() {
                        // Token j is predicted by the prompt (j == 0) or by token j-1.
                        let row: Int32 = j == 0 ? -1 : rows[i][j - 1]
                        _ = ear.withRow(row) { logits, z in scores[i] += weight * (logits[Int(t)] - z) }
                    }
                }
            }
            if ok {
                for (i, plan) in plans.enumerated() {
                    let logp = scores[i] - plan.cost
                    finished[plan.text] = Result(text: plan.text, logp: logp, tokens: plan.tokens.map { Int32($0) })
                }
            }
            release()
        }
        let results = finished.values.sorted { $0.logp > $1.logp }.prefix(config.results)
        var seenLeads = Set<String>()
        let rankedLeads = leads.sorted { $0.logp > $1.logp }.filter { seenLeads.insert($0.text + "\u{1}\($0.end)").inserted }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        return Answer(
            context: context, keys: keys, results: Array(results), leads: Array(rankedLeads.prefix(40)),
            milliseconds: elapsed, steps: steps, promptTokens: tingTokens.count,
            decodedPromptTokens: decodedPrompt, decodeMilliseconds: Double(decodeNanos) / 1e6
        )
    }

    /// Forget the cached prompts (e.g. after the context changed wholesale).
    public func reset() {
        ting?.reset()
        zhi?.reset()
    }
}
