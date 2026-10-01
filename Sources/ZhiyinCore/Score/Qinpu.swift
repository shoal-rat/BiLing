import Foundation

/// 琴谱 · The score.
///
/// The deterministic half of 知音: a dictionary of words with unigram
/// log-probabilities, read against the keys with the same three rules the
/// listener uses. It answers in about a millisecond, never needs the GPU, and
/// is what you type with when 子期 is resting. It also supplies the words and
/// single characters that let you pick part of a long input.
public final class Qinpu: @unchecked Sendable {
    public let trie: CharTrie

    /// Price of reading one character by initial or prefix instead of in
    /// full (nats). Spelled-out readings win whenever both exist.
    public var abbreviationCost: Float = 1.6
    /// Price of a character read through a slip of the finger (走音).
    public var slipCost: Float = 6.0
    /// Cap on dictionary edges kept per (start, end) span.
    public var edgesPerSpan = 10

    public init(path: String) throws {
        trie = try CharTrie(path: path)
        guard trie.kind == .words else { throw CharTrie.LoadError.malformed("not a word trie") }
    }

    public var syllables: SyllableTable { trie.syllables }

    public struct Phrase: Sendable, Hashable {
        public let text: String
        public let start: Int
        public let end: Int
        public let logp: Float
        public let abbreviated: Int
        public var cost: Float { logp }
    }

    /// Words readable from p, the best few for each end position.
    public func phrases(_ reader: KeyReader, from p: Int, maxChars: Int = 8) -> [Phrase] {
        let matches = trie.walk(reader, from: p, maxChars: maxChars)
        // Rank by score per end first; only the survivors become strings.
        var bySpan: [Int: [(Float, CharTrie.Match)]] = [:]
        for m in matches {
            let score = trie.logp(Int(m.entry)) - abbreviationCost * Float(m.abbreviated) - slipCost * Float(m.slips)
            bySpan[Int(m.end), default: []].append((score, m))
        }
        var out: [Phrase] = []
        for (end, list) in bySpan {
            let kept = list.count > edgesPerSpan
                ? Array(list.sorted { $0.0 > $1.0 }.prefix(edgesPerSpan))
                : list
            for (score, m) in kept {
                out.append(Phrase(text: trie.text(Int(m.entry)), start: p, end: end, logp: score, abbreviated: Int(m.abbreviated)))
            }
        }
        return out
    }

    /// Phrases from every reachable position, computed once per key sequence.
    public final class Lattice {
        public let reader: KeyReader
        private let qinpu: Qinpu
        private var cache: [Int: [Phrase]] = [:]
        init(_ qinpu: Qinpu, _ reader: KeyReader) { self.qinpu = qinpu; self.reader = reader }
        public func phrases(from p: Int) -> [Phrase] {
            if let hit = cache[p] { return hit }
            let list = qinpu.phrases(reader, from: p)
            cache[p] = list
            return list
        }
    }

    public func lattice(_ reader: KeyReader) -> Lattice { Lattice(self, reader) }

    public struct Sentence: Sendable {
        public let text: String
        public let logp: Float
        public let pieces: [Phrase]
    }

    /// The k best readings of the whole key sequence (exact k-best Viterbi
    /// over the word lattice).
    public func decode(_ reader: KeyReader, nbest: Int = 5) -> [Sentence] {
        decode(lattice(reader), nbest: nbest)
    }

    public func decode(_ lattice: Lattice, nbest: Int = 5) -> [Sentence] {
        let reader = lattice.reader
        let n = reader.count
        guard n > 0 else { return [] }
        struct Path { let score: Float; let from: Int; let rank: Int; let phrase: Phrase? }
        var best = [[Path]](repeating: [], count: n + 1)
        best[0] = [Path(score: 0, from: -1, rank: -1, phrase: nil)]
        for p in 0..<n where !best[p].isEmpty {
            for phrase in lattice.phrases(from: p) {
                var list = best[phrase.end]
                for (rank, path) in best[p].enumerated() {
                    list.append(Path(score: path.score + phrase.logp, from: p, rank: rank, phrase: phrase))
                }
                list.sort { $0.score > $1.score }
                if list.count > nbest { list.removeLast(list.count - nbest) }
                best[phrase.end] = list
            }
        }
        var sentences: [Sentence] = []
        var seen = Set<String>()
        for path in best[n] {
            var pieces: [Phrase] = []
            var cursor = path
            var position = n
            while let phrase = cursor.phrase {
                pieces.append(phrase)
                let previous = best[cursor.from][cursor.rank]
                position = cursor.from
                cursor = previous
            }
            _ = position
            pieces.reverse()
            let text = pieces.map(\.text).joined()
            if seen.insert(text).inserted {
                sentences.append(Sentence(text: text, logp: path.score, pieces: pieces))
            }
        }
        return sentences
    }

    /// Words and characters that read a prefix of the keys, for picking part
    /// of a long input: longest reading first, then by probability.
    public func prefixes(_ reader: KeyReader, limit: Int = 24) -> [Phrase] {
        prefixes(lattice(reader), limit: limit)
    }

    public func prefixes(_ lattice: Lattice, limit: Int = 24) -> [Phrase] {
        let all = lattice.phrases(from: 0)
        return all
            .sorted { a, b in
                if a.end != b.end { return a.end > b.end }
                return a.logp > b.logp
            }
            .prefix(limit)
            .map { $0 }
    }
}
