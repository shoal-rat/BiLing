import Foundation

/// Exhaustive n-best decoding by enumerating every complete path.
///
/// This is the test oracle for `LatticeDecoder`, nothing more. It walks every
/// path from position 0 to the end of the input, so its cost is exponential in
/// input length — a dense 20-key lattice would enumerate billions of paths.
/// It must never run at runtime; it is `internal` and guarded by a length
/// precondition precisely so it cannot be wired into the keystroke path by
/// accident. The differential tests use it to measure how far the pruned
/// production decoder is from the true ranking.
///
/// The semantics mirror `LatticeDecoder.nBest` exactly, because the tests
/// compare outputs verbatim:
/// * edges score through the same shared `LatticeEdge.score(afterWord:...)`
///   — the formula lives in one place so the two decoders cannot drift;
/// * only multi-segment paths are returned (single words are offered through
///   their own candidate source, not the sentence decoder);
/// * paths deduplicate by surface text, keeping the best-scoring reading;
/// * results sort by descending score, ties broken by text so the reference
///   itself is deterministic.
enum ReferenceDecoder {
    static func nBest(
        edges: [LatticeEdge],
        inputLength: Int,
        limit: Int,
        logTotalWeight: Double,
        transition: (String, String) -> Double
    ) -> [LatticeDecoder.Path] {
        // The oracle's contract: small lattices only. Beyond this length the
        // enumeration can explode past what a test run should ever pay for.
        precondition(inputLength <= 12, "ReferenceDecoder is exponential; test-only")
        guard inputLength > 0, !edges.isEmpty, limit > 0 else { return [] }

        var edgesFrom = [[LatticeEdge]](repeating: [], count: inputLength + 1)
        // Zero- or negative-span edges would make enumeration non-terminating;
        // the production lattice never contains them, so the oracle rejects
        // them rather than tolerating an input the real decoder never sees.
        for edge in edges where edge.start >= 0 && edge.end <= inputLength && edge.end > edge.start {
            edgesFrom[edge.start].append(edge)
        }

        struct Complete {
            var score: Double
            var words: [String]
            var weights: [Double]
            var pinyin: [String]
        }
        var bestByText: [String: Complete] = [:]

        var words: [String] = []
        var weights: [Double] = []
        var pinyin: [String] = []

        func descend(position: Int, previous: String, score: Double) {
            if position == inputLength {
                // Mirrors LatticeDecoder: single-word paths are not sentences.
                guard words.count > 1 else { return }
                let text = words.joined()
                if let existing = bestByText[text], existing.score >= score { return }
                bestByText[text] = Complete(
                    score: score, words: words, weights: weights, pinyin: pinyin
                )
                return
            }
            for edge in edgesFrom[position] {
                words.append(edge.text)
                weights.append(edge.weight)
                pinyin.append(edge.pinyin)
                descend(
                    position: edge.end,
                    previous: edge.text,
                    score: score + edge.score(
                        afterWord: previous,
                        logTotalWeight: logTotalWeight,
                        transition: transition
                    )
                )
                words.removeLast()
                weights.removeLast()
                pinyin.removeLast()
            }
        }
        descend(position: 0, previous: DictTrie.sentenceStart, score: 0)

        return bestByText
            .map { text, complete in
                LatticeDecoder.Path(
                    text: text,
                    words: complete.words,
                    weights: complete.weights,
                    pinyin: complete.pinyin,
                    score: complete.score,
                    segments: complete.words.count
                )
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
            .prefix(limit)
            .map { $0 }
    }
}
