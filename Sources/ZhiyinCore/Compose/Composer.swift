/// What 子期 heard for one key sequence, in terms the composer understands
/// (ZhiyinListener converts its answers into this).
public struct Heard: Sendable {
    public struct Reading: Sendable { public let text: String; public let logp: Float
        public init(text: String, logp: Float) { self.text = text; self.logp = logp } }
    public struct Lead: Sendable { public let text: String; public let end: Int; public let logp: Float
        public init(text: String, end: Int, logp: Float) { self.text = text; self.end = end; self.logp = logp } }
    public let keys: String
    public let readings: [Reading]
    public let leads: [Lead]
    public init(keys: String, readings: [Reading], leads: [Lead]) {
        self.keys = keys
        self.readings = readings
        self.leads = leads
    }
}

/// Arranges the candidate list: what fills the strings of the panel, and in
/// which order.
///
///   1. readings of the whole input — 子期's when it has spoken, else 琴谱's;
///   2. what 默契 remembers you choosing for exactly these keys, promoted
///      when 子期 does not strongly disagree;
///   3. words and characters for the beginning of the input, longest first,
///      so a long input can be taken apart piece by piece;
///   4. the keys themselves.
public enum Composer {
    public struct Settings: Sendable {
        /// How much worse (nats) than 子期's best a remembered choice may be
        /// and still be promoted to the top.
        public var rememberMargin: Float = 4.0
        public var wholeReadings = 4
        public var limit = 45
        public init() {}
    }

    public static func compose(
        keys: String,
        reader: KeyReader,
        heard: Heard?,
        qinpu: Qinpu?,
        remembered: [Moqi.Memory],
        settings: Settings = Settings()
    ) -> [Candidate] {
        let n = reader.count
        var out: [Candidate] = []
        var seen = Set<String>()
        func add(_ c: Candidate) {
            guard !c.text.isEmpty, seen.insert(c.text + "\u{1}\(c.consumed)").inserted else { return }
            out.append(c)
        }

        // 1. Whole-input readings.
        var whole: [Candidate] = []
        if let heard, heard.keys == keys, !heard.readings.isEmpty {
            whole = heard.readings.prefix(settings.wholeReadings + 2).map {
                Candidate(text: $0.text, consumed: n, score: $0.logp, voice: .ziqi)
            }
        }
        let sentences = qinpu?.decode(reader, nbest: 3) ?? []
        if whole.isEmpty {
            whole = sentences.map { Candidate(text: $0.text, consumed: n, score: $0.logp, voice: .qinpu) }
        }

        // 2. Remembered choices for exactly these keys.
        let exact = remembered.filter { $0.keys == keys }.sorted { $0.strength > $1.strength }
        if let first = exact.first {
            let best = whole.first?.score ?? 0
            if let i = whole.firstIndex(where: { $0.text == first.text }) {
                let candidate = whole[i]
                let modelAgrees = candidate.voice != .ziqi || best - candidate.score <= settings.rememberMargin
                if i > 0, modelAgrees, first.chosenOverTop {
                    whole.remove(at: i)
                    whole.insert(Candidate(text: candidate.text, consumed: n, score: best + 0.01, voice: .moqi), at: 0)
                }
            } else {
                // Not something 子期 would say on its own (a name, a coinage):
                // offer it right after the best reading, or first once it has
                // been chosen repeatedly.
                let slot = first.strength >= 2 && first.chosenOverTop ? 0 : min(1, whole.count)
                whole.insert(Candidate(text: first.text, consumed: n, score: best, voice: .moqi), at: slot)
            }
        }
        for c in whole.prefix(settings.wholeReadings) { add(c) }

        // 3. Pieces for the start of the input.
        struct Piece { let text: String; let end: Int; let score: Float; let voice: Candidate.Voice }
        var pieces: [Piece] = []
        var leadScore: [String: Float] = [:]
        if let heard, heard.keys == keys {
            for lead in heard.leads where lead.end < n && isHan(lead.text) {
                let key = lead.text + "\u{1}\(lead.end)"
                if leadScore[key] == nil {
                    leadScore[key] = lead.logp
                    pieces.append(Piece(text: lead.text, end: lead.end, score: lead.logp, voice: .ziqi))
                }
            }
        }
        if let qinpu {
            for phrase in qinpu.prefixes(reader, limit: 60) where phrase.end < n || whole.isEmpty {
                let key = phrase.text + "\u{1}\(phrase.end)"
                guard leadScore[key] == nil else { continue }
                // Dictionary pieces rank below the model's pieces of the same
                // length unless the model never considered them.
                pieces.append(Piece(text: phrase.text, end: phrase.end, score: phrase.logp - 30, voice: .qinpu))
            }
        }
        for m in remembered where m.keys != keys && keys.hasPrefix(m.keys) {
            pieces.append(Piece(text: m.text, end: m.keys.utf8.count, score: 10 + Float(m.strength), voice: .moqi))
        }
        pieces.sort { a, b in
            if a.end != b.end { return a.end > b.end }
            return a.score > b.score
        }
        for p in pieces { add(Candidate(text: p.text, consumed: p.end, score: p.score, voice: p.voice)) }
        if out.count > settings.limit { out.removeLast(out.count - settings.limit) }

        // 4. The keys as typed.
        add(Candidate(text: keys.replacingOccurrences(of: "'", with: ""), consumed: n, score: -1e9, voice: .literal))
        return out
    }

    static func isHan(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) }
    }
}
