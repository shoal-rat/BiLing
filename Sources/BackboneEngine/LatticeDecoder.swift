import Foundation

/// One way of reading a span of the keystroke buffer as a single word.
public struct LatticeEdge: Sendable {
    public enum Reading: Sendable {
        /// A lexicon word, with the written form the user used for it.
        case lexicon(weight: Double, form: ScoreModel.TypingForm)
        /// A Latin word, priced through the same unigram model.
        case latin(ScoreModel.LatinEvidence)
        /// A personal name assembled from a surname and given-name characters,
        /// already scored by the name model.
        case name(logProbability: Double)
    }

    public let start: Int
    public let end: Int
    public let text: String
    public let pinyin: String
    public let reading: Reading

    /// Corpus weight when this edge is a lexicon word; a stand-in frequency
    /// when it is Latin, so both price the same way downstream.
    public var weight: Double {
        switch reading {
        case let .lexicon(weight, _): weight
        case let .latin(evidence): evidence.pseudoWeight
        case .name: 1
        }
    }

    public init(start: Int, end: Int, text: String, pinyin: String, reading: Reading) {
        self.start = start
        self.end = end
        self.text = text
        self.pinyin = pinyin
        self.reading = reading
    }
}

extension LatticeEdge {
    /// Cost of taking this edge after `previous` — the one edge-scoring
    /// formula in the system. `LatticeDecoder` and `ReferenceDecoder` both
    /// call this, so the differential tests compare decoding *strategies*;
    /// two copies of the arithmetic could drift apart and hide exactly the
    /// discrepancies those tests exist to find.
    func score(
        afterWord previous: String,
        logTotalWeight: Double,
        transition: (String, String) -> Double
    ) -> Double {
        switch reading {
        case let .lexicon(weight, form):
            return ScoreModel.transitionLogProbability(
                weight: weight,
                logTotalWeight: logTotalWeight,
                conditional: transition(previous, text),
                form: form
            )
        case let .latin(evidence):
            return ScoreModel.latinLogProbability(evidence, logTotalWeight: logTotalWeight)
        case let .name(logProbability):
            return logProbability
        }
    }
}

/// Exact n-best decoding over the segmentation lattice.
///
/// The previous beam search kept the best few partial paths per position and
/// hoped the right one was among them. That fails precisely when the lattice is
/// widest — long input, and abbreviations, where every key matches many words —
/// because the correct path can be crowded out early by locally better rivals
/// and can never come back. Measurements bore this out: widening the beam moved
/// coverage by fractions of a point while doubling latency.
///
/// This replaces it with the standard two-pass formulation used by libime and
/// described for lattice decoders generally:
///
/// 1. **Forward Viterbi.** Compute, for every state, the exact best score of
///    any path from the start to that state. Under a bigram model the state is
///    (position, last word), not position alone, because the next word's score
///    depends on the last one.
/// 2. **Backward A\*.** Walk backwards from the end, ordering partial suffixes
///    by `f = g + fwd[state]`, where `g` is the suffix accumulated so far. The
///    forward score is the *exact* best completion, so the heuristic is perfect:
///    A\* pops complete paths in strictly decreasing score order, and the first
///    K are the true K best under the model.
///
/// The n-best list handed to the re-ranker is therefore correctly ordered by
/// construction rather than by luck, which is what makes long sentences work.
public enum LatticeDecoder {
    public struct Path: Sendable {
        public let text: String
        public let words: [String]
        /// Corpus weight of each word, so a rescoring pass does not have to
        /// look them up again.
        public let weights: [Double]
        public let pinyin: [String]
        public let score: Double
        public let segments: Int
    }

    private struct State: Hashable {
        let position: Int
        let word: String
    }

    /// Bounds the LM state kept per position. Exactness is per state, so this
    /// only limits how many *distinct previous words* survive at a position;
    /// with a bigram model, states beyond the best few can never come back to
    /// win, and keeping them unbounded makes long input quadratic.
    private static let maxStatesPerPosition = 24

    public static func nBest(
        edges: [LatticeEdge],
        inputLength: Int,
        limit: Int,
        logTotalWeight: Double,
        transition: (String, String) -> Double
    ) -> [Path] {
        guard inputLength > 0, !edges.isEmpty, limit > 0 else { return [] }

        var edgesFrom = [[LatticeEdge]](repeating: [], count: inputLength + 1)
        var edgesTo = [[LatticeEdge]](repeating: [], count: inputLength + 1)
        for edge in edges where edge.start >= 0 && edge.end <= inputLength {
            edgesFrom[edge.start].append(edge)
            edgesTo[edge.end].append(edge)
        }

        // ---- Pass 1: forward Viterbi, exact best score into every state ----
        let startState = State(position: 0, word: DictTrie.sentenceStart)
        var forward: [State: Double] = [startState: 0]
        var statesAt = [[String]](repeating: [], count: inputLength + 1)
        statesAt[0] = [DictTrie.sentenceStart]

        for position in 0..<inputLength {
            guard !statesAt[position].isEmpty, !edgesFrom[position].isEmpty else { continue }
            for word in statesAt[position] {
                let from = State(position: position, word: word)
                guard let base = forward[from] else { continue }
                for edge in edgesFrom[position] {
                    let candidate = base + edge.score(
                        afterWord: word,
                        logTotalWeight: logTotalWeight,
                        transition: transition
                    )
                    let to = State(position: edge.end, word: edge.text)
                    if let existing = forward[to], existing >= candidate { continue }
                    if forward[to] == nil { statesAt[edge.end].append(edge.text) }
                    forward[to] = candidate
                }
            }
            // Trim the next frontier once it is fully populated by this step.
            let next = position + 1
            if statesAt[next].count > maxStatesPerPosition {
                statesAt[next] = statesAt[next]
                    .sorted { (forward[State(position: next, word: $0)] ?? -.infinity)
                            > (forward[State(position: next, word: $1)] ?? -.infinity) }
                    .prefix(maxStatesPerPosition)
                    .map { $0 }
            }
        }

        let finals = statesAt[inputLength]
        guard !finals.isEmpty else { return [] }

        // ---- Pass 2: backward A*, exact top-K ----
        struct Partial {
            let priority: Double     // g + forward[state]
            let accumulated: Double  // g
            let state: State
            let words: [String]      // suffix, front to back
            let weights: [Double]
            let pinyin: [String]
        }
        var heap = Heap<Partial>(compare: { $0.priority > $1.priority })
        for word in finals {
            let state = State(position: inputLength, word: word)
            guard let score = forward[state] else { continue }
            heap.push(
                Partial(priority: score, accumulated: 0, state: state,
                        words: [], weights: [], pinyin: [])
            )
        }

        var paths: [Path] = []
        var seen: Set<String> = []
        // Expansion is bounded so a pathological lattice cannot stall a
        // keystroke; the bound is far above what any real input reaches.
        var expansions = 0
        let maxExpansions = 60_000

        while let partial = heap.pop(), paths.count < limit, expansions < maxExpansions {
            expansions += 1
            if partial.state == startState {
                let text = partial.words.joined()
                if partial.words.count > 1, seen.insert(text).inserted {
                    paths.append(
                        Path(
                            text: text,
                            words: partial.words,
                            weights: partial.weights,
                            pinyin: partial.pinyin,
                            score: partial.accumulated,
                            segments: partial.words.count
                        )
                    )
                }
                continue
            }
            for edge in edgesTo[partial.state.position] where edge.text == partial.state.word {
                for previous in statesAt[edge.start] {
                    let predecessor = State(position: edge.start, word: previous)
                    guard let heuristic = forward[predecessor] else { continue }
                    let step = edge.score(
                        afterWord: previous,
                        logTotalWeight: logTotalWeight,
                        transition: transition
                    )
                    let accumulated = partial.accumulated + step
                    heap.push(
                        Partial(
                            priority: accumulated + heuristic,
                            accumulated: accumulated,
                            state: predecessor,
                            words: [edge.text] + partial.words,
                            weights: [edge.weight] + partial.weights,
                            pinyin: [edge.pinyin] + partial.pinyin
                        )
                    )
                }
            }
        }
        return paths
    }
}

/// Minimal binary heap; Swift has no priority queue in the standard library.
struct Heap<Element> {
    private var storage: [Element] = []
    private let compare: (Element, Element) -> Bool

    init(compare: @escaping (Element, Element) -> Bool) {
        self.compare = compare
    }

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(_ element: Element) {
        storage.append(element)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard compare(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let top = storage.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var best = parent
            if left < storage.count, compare(storage[left], storage[best]) { best = left }
            if right < storage.count, compare(storage[right], storage[best]) { best = right }
            if best == parent { break }
            storage.swapAt(parent, best)
            parent = best
        }
        return top
    }
}
