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
        /// 知意's weight when there is no context at all: with nothing to
        /// read, the plain base model leans toward the openings of web and
        /// news documents (看点是 for kandianshi), so 听音 — which learned
        /// chat — should lead.
        public var zhiWeightCold: Float = 0.6
        /// What 知意 reads before an empty context: a register hint. The KV
        /// cache keeps it, so it costs nothing after the first keystroke.
        public var coldPrefix = ""
        /// Partial hypotheses are ranked by score + perKey × keys read, so one
        /// that has read more of the keys is not ranked down for having paid.
        public var perKey: Float = 1.0
        /// Typing channel: cost of a character read by initial or prefix…
        public var abbreviationCost: Float = 1.0
        /// …and of a character read through a slip (走音: neighbour key,
        /// swapped, missing or doubled letter).
        public var slipCost: Float = 5.0
        /// Normalise the two ears' product once over the whole vocabulary
        /// (log of p听音·p知意^w, renormalised) instead of adding the two
        /// separately normalised log-probabilities. Needed for a 听音 trained
        /// on the product (train_poe.py): on its own it is not calibrated.
        public var renormalize = false
        /// Cost of a Latin token (keeps pinyin from turning into English)…
        public var latinCost: Float = 3.0
        /// …and extra for a capitalised word (Haroen): a name the keys happen
        /// to spell is far less likely than pinyin with a slip.
        public var properNounCost: Float = 3.0
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
    /// Dictionary readings that ride along in the beam's batches.
    static let maxRiders = 4
    public var config: Config
    public let description: String
    public let hasTingyin: Bool
    private let model: OpaquePointer
    /// A separate, fused 听音 model (LoRA merged in) when one is given in
    /// place of an adapter: no per-step LoRA matmuls, at the price of a
    /// second set of weights in memory.
    private var tingModel: OpaquePointer?
    /// A different (larger) base for 知意; it must share Qwen3's tokenizer.
    private var zhiModel: OpaquePointer?
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

        /// A hypothesis's raw logit row, valid until the next decode
        /// (row < 0: the prompt's own next-token row).
        func rowPointer(_ row: Int32) -> UnsafePointer<Float>? {
            if row < 0 {
                return cachedLogits.withUnsafeBufferPointer { UnsafePointer($0.baseAddress) }
            }
            return llama_get_logits_ith(ctx, row).map { UnsafePointer($0) }
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

    public init(modelPath: String, adapterPath: String?, vocabularyPath: String, config: Config? = nil,
                zhiModelPath: String? = nil) throws {
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
        var fused: OpaquePointer?
        if let adapterPath, FileManager.default.fileExists(atPath: adapterPath) {
            let size = (try? FileManager.default.attributesOfItem(atPath: adapterPath)[.size] as? Int) ?? 0
            if size > 200_000_000 {
                // A whole model, not an adapter: 听音 fused.
                fused = llama_model_load_from_file(adapterPath, modelParams)
                if fused == nil {
                    llama_model_free(model)
                    throw LoadError.adapter(adapterPath)
                }
            } else {
                adapter = llama_adapter_lora_init(model, adapterPath)
                if adapter == nil {
                    llama_model_free(model)
                    throw LoadError.adapter(adapterPath)
                }
            }
        }
        tingModel = fused
        hasTingyin = adapter != nil || fused != nil
        let chosen = config ?? (hasTingyin ? Config() : Config.zhiOnly)
        self.config = chosen
        maxSequences = Int32(max(chosen.beam, 12) + 1)
        let padding = ProcessInfo.processInfo.environment["ZHIYIN_PAD"] != nil ? chosen.beam : 0
        let sequences = maxSequences + Int32(Ziqi.maxRiders) + Int32(padding)

        func makeContext(_ model: OpaquePointer) -> OpaquePointer? {
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
        if let zhiModelPath {
            guard let m = llama_model_load_from_file(zhiModelPath, modelParams) else {
                llama_model_free(model)
                throw LoadError.model(zhiModelPath)
            }
            zhiModel = m
        }
        guard let zhiContext = makeContext(zhiModel ?? model) else {
            llama_model_free(model)
            throw LoadError.context
        }
        zhi = Ear(ctx: zhiContext, vocabularySize: vocabularySize)
        let firstPad = maxSequences + Int32(Ziqi.maxRiders)
        let padSequences = (0..<padding).map { firstPad + Int32($0) }
        zhi?.name = "zhi"
        zhi?.padTo = padding
        zhi?.padSequences = padSequences
        if adapter != nil || fused != nil {
            guard let tingContext = makeContext(fused ?? model) else {
                zhi = nil
                llama_model_free(model)
                throw LoadError.context
            }
            if let adapter {
                var adapters: [OpaquePointer?] = [adapter]
                var scales: [Float] = [1.0]
                _ = llama_set_adapters_lora(tingContext, &adapters, 1, &scales)
            }
            ting = Ear(ctx: tingContext, vocabularySize: vocabularySize)
            ting?.name = "ting"
            ting?.padTo = padding
            ting?.padSequences = padSequences
        }

        var buffer = [CChar](repeating: 0, count: 160)
        llama_model_desc(model, &buffer, buffer.count)
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let megabytes = Double(llama_model_size(model)) / 1_048_576
        description = "\(name) · \(Int(megabytes)) MB · \(fused != nil ? "听音(合并)+知意" : adapter != nil ? "听音+知意" : "知意")"
    }

    deinit {
        // Contexts first; the model (and its adapter) must outlive them.
        ting = nil
        zhi = nil
        if let tingModel { llama_model_free(tingModel) }
        if let zhiModel { llama_model_free(zhiModel) }
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

    /// 知意's prompt: the context alone, after a document boundary (or the
    /// register hint when there is no context).
    func zhiPrompt(_ context: [llama_token]) -> [llama_token] {
        if context.isEmpty, !config.coldPrefix.isEmpty {
            return [Ziqi.endOfText] + tokenize(config.coldPrefix)
        }
        return [Ziqi.endOfText] + context
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

    private var productScratch: [Float] = []

    /// (wt·lseT + wz·lseZ) − lse(wt·t + wz·z): what turns the sum of the two
    /// separately normalised log-probabilities into the renormalised product.
    private func productCorrection(_ t: UnsafePointer<Float>, _ z: UnsafePointer<Float>, wt: Float, wz: Float,
                                   lseT: Float, lseZ: Float) -> Float {
        let n = vocabularySize
        if productScratch.count != n { productScratch = [Float](repeating: 0, count: n) }
        var a = wt
        var b = wz
        var maximum: Float = 0
        var sum: Float = 0
        productScratch.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            vDSP_vsmul(t, 1, &a, out, 1, vDSP_Length(n))
            vDSP_vsma(z, 1, &b, out, 1, out, 1, vDSP_Length(n))
            vDSP_maxv(out, 1, &maximum, vDSP_Length(n))
            var negative = -maximum
            vDSP_vsadd(out, 1, &negative, out, 1, vDSP_Length(n))
            var count = Int32(n)
            vvexpf(out, out, &count)
            vDSP_sve(out, 1, &sum, vDSP_Length(n))
        }
        return wt * lseT + wz * lseZ - (maximum + log(sum))
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
            let text = piece(llama_token(token)).trimmingCharacters(in: .whitespaces)
            let scalars = Array(text.unicodeScalars)
            let capitalised = scalars.count >= 3 && CharacterSet.uppercaseLetters.contains(scalars[0])
                && scalars.dropFirst().allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
            out.append(Option(token: llama_token(token), end: end,
                              cost: config.latinCost + (capitalised ? config.properNounCost : 0), slips: 0))
        }
        cache[p] = out
        return out
    }

    /// How `text` (BPE-tokenized) reads the keys: the per-token channel
    /// costs of the cheapest alignment that ends exactly at the end of the
    /// keys, or nil if the keys cannot spell it.
    private func alignment(_ tokens: [llama_token], _ reader: KeyReader, cache: inout [Int: [Option]]) -> [Float]? {
        struct State { var cost: Float; var slips: Int; var costs: [Float] }
        var states: [Int: State] = [0: State(cost: 0, slips: 0, costs: [])]
        for t in tokens {
            var next: [Int: State] = [:]
            for (p, st) in states {
                for o in options(reader, at: p, cache: &cache) where o.token == t {
                    let slips = st.slips + o.slips
                    guard slips <= KeyReader.maxSlips else { continue }
                    let c = st.cost + o.cost
                    if next[o.end].map({ c < $0.cost }) ?? true {
                        next[o.end] = State(cost: c, slips: slips, costs: st.costs + [o.cost])
                    }
                }
            }
            if next.isEmpty { return nil }
            states = next
        }
        return states[reader.count]?.costs
    }

    /// Reads `keys` in the light of `context`. Returns nil when cancelled
    /// (checked between decode steps) or on a decode failure.
    ///
    /// `rescue` are readings found elsewhere (琴谱's sentences, 默契's
    /// memories). The beam can miss a name or an idiom the dictionary knows;
    /// these ride along in the beam's own batches — one forced token per
    /// step, no extra decode — and are ranked together with its results.
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
        let zhiWeight = ting == nil ? 1 : (context.isEmpty ? config.zhiWeightCold : config.zhiWeight)
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

        // 琴谱补漏 riders: readings found elsewhere, forced token by token in
        // the same batches as the beam — no extra decode calls.
        struct Rider {
            let text: String
            let tokens: [llama_token]
            let costs: [Float]
            var emitted = 0
            var logp: Float = 0
            let sequence: Int32
            var row: Int32 = -1
        }
        var riders: [Rider] = []
        for text in rescue where !text.isEmpty && riders.count < Ziqi.maxRiders {
            let tokens = tokenize(text)
            guard !tokens.isEmpty, tokens.count <= 16,
                  let costs = alignment(tokens, reader, cache: &optionCache) else { continue }
            let sequence = maxSequences + Int32(riders.count)
            for ear in ears { llama_memory_seq_cp(ear.memory, 0, sequence, -1, -1) }
            riders.append(Rider(text: text, tokens: tokens, costs: costs, sequence: sequence))
        }

        func release() {
            for ear in ears { ear.clearCandidates(maxSequences + Int32(Ziqi.maxRiders)) }
        }

        var beamAlive = true
        for step in 0..<(n + 2) {
            if isCancelled() { release(); return nil }
            struct Expansion { let score: Float; let rank: Float; let option: Option; let parent: Int }
            var expansions: [Expansion] = []
            if beamAlive {
                for (index, h) in live.enumerated() {
                    let opts = options(reader, at: h.position, cache: &optionCache)
                    guard !opts.isEmpty else { continue }
                    var combined = [Float](repeating: 0, count: opts.count)
                    var lseT: Float = 0
                    var lseZ: Float = 0
                    if let ting {
                        let ok = ting.withRow(h.row) { row, z in
                            lseT = z
                            for (i, o) in opts.enumerated() { combined[i] += tingWeight * (row[Int(o.token)] - z) }
                        }
                        guard ok else { release(); return nil }
                    }
                    if let zhi {
                        let ok = zhi.withRow(h.row) { row, z in
                            lseZ = z
                            for (i, o) in opts.enumerated() { combined[i] += zhiWeight * (row[Int(o.token)] - z) }
                        }
                        guard ok else { release(); return nil }
                    }
                    if config.renormalize, let ting, let zhi,
                       let t = ting.rowPointer(h.row), let z = zhi.rowPointer(h.row) {
                        let c = productCorrection(t, z, wt: tingWeight, wz: zhiWeight, lseT: lseT, lseZ: lseZ)
                        for i in combined.indices { combined[i] += c }
                    }
                    for (i, o) in opts.enumerated() where h.slips + o.slips <= maxSlips {
                        let score = h.logp + combined[i] - o.cost
                        expansions.append(Expansion(score: score, rank: score + config.perKey * Float(o.end), option: o, parent: index))
                        if step == 0 { leads.append(Lead(text: piece(o.token), end: o.end, logp: score)) }
                    }
                }
            }
            // Riders take their forced next token.
            for r in riders.indices where riders[r].emitted < riders[r].tokens.count {
                let t = riders[r].tokens[riders[r].emitted]
                var gain: Float = 0
                var lseT: Float = 0
                var lseZ: Float = 0
                if let ting { _ = ting.withRow(riders[r].row) { row, z in lseT = z; gain += tingWeight * (row[Int(t)] - z) } }
                if let zhi { _ = zhi.withRow(riders[r].row) { row, z in lseZ = z; gain += zhiWeight * (row[Int(t)] - z) } }
                if config.renormalize, let ting, let zhi,
                   let tp = ting.rowPointer(riders[r].row), let zp = zhi.rowPointer(riders[r].row) {
                    gain += productCorrection(tp, zp, wt: tingWeight, wz: zhiWeight, lseT: lseT, lseZ: lseZ)
                }
                riders[r].logp += gain - riders[r].costs[riders[r].emitted]
                riders[r].emitted += 1
                if riders[r].emitted == riders[r].tokens.count {
                    let text = riders[r].text
                    if finished[text].map({ $0.logp < riders[r].logp }) ?? true {
                        finished[text] = Result(text: text, logp: riders[r].logp, tokens: riders[r].tokens.map { Int32($0) })
                    }
                }
            }

            var next: [(parent: Int, option: Option, score: Float)] = []
            if beamAlive {
                expansions.sort { $0.rank > $1.rank }
                var bestFinal = finished.values.map(\.logp).max() ?? -.infinity
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
                if next.isEmpty || (!finished.isEmpty && next.allSatisfy({ $0.score < bestFinal - 8 })) {
                    beamAlive = false
                    next = []
                }
            }

            // Re-assign KV sequences, identically in every ear: dead parents
            // release theirs, the first child inherits its parent's, siblings
            // get copies.
            var children: [Hypothesis] = []
            if beamAlive {
                var childCount = [Int](repeating: 0, count: live.count)
                for c in next { childCount[c.parent] += 1 }
                for (i, h) in live.enumerated() where childCount[i] == 0 && h.sequence != 0 {
                    for ear in ears { llama_memory_seq_rm(ear.memory, h.sequence, -1, -1) }
                    freeSequences.append(h.sequence)
                }
                var inherited = [Bool](repeating: false, count: live.count)
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
            }
            // Riders that still have tokens to go ride in the same batch.
            var batch = children.map { ($0.tokens.last!, $0.sequence) }
            for r in riders.indices where riders[r].emitted < riders[r].tokens.count {
                riders[r].row = Int32(batch.count)
                batch.append((riders[r].tokens[riders[r].emitted - 1], riders[r].sequence))
            }
            if batch.isEmpty { break }
            if isCancelled() { release(); return nil }
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
        release()
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
