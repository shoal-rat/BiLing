import Foundation
import Testing

@testable import BackboneEngine

/// Differential testing of `LatticeDecoder` against `ReferenceDecoder`.
///
/// The production decoder is exact *given the states that survive its
/// per-position frontier cap* (`maxStatesPerPosition = 24`) and approximate
/// with respect to the full lattice. These tests measure that gap instead of
/// asserting it away: random lattices shaped like production ones, decoded by
/// both, with hard invariants that must hold regardless of approximation and
/// aggregate quality thresholds set from measured runs.

// MARK: - Deterministic randomness

/// SplitMix64. `SystemRandomNumberGenerator` reseeds per process, which would
/// make a failing lattice unreproducible; every random draw here goes through
/// this generator with a fixed seed so a failure names its own test case.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Modulo bias is irrelevant at test ranges (spans ≤ 64 values).
    mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func double01() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * double01()
    }

    mutating func chance(_ probability: Double) -> Bool {
        double01() < probability
    }
}

// MARK: - Synthetic model

/// Matches the real corpus scale (log of total lexicon weight ≈ 4×10⁸) so
/// unigram log-probabilities land in the same range the decoder sees live.
private let testLogTotalWeight = log(4.0e8)

/// FNV-1a. `String.hashValue` is salted per process, which would randomise
/// the transition model between runs.
private func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in string.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    return hash
}

/// Stand-in bigram model: most pairs unseen (0), a sparse minority strongly
/// predicted. The sparsity matters — pruning can only be caught out when a
/// weak-unigram word carries a strong *outgoing* bigram, which is exactly the
/// shape real bigram tables have.
private func syntheticTransition(_ previous: String, _ next: String) -> Double {
    let hash = stableHash(previous + "\u{1}" + next)
    guard hash % 8 == 0 else { return 0 }
    return Double(hash % 1000) / 1000.0 * 0.4
}

// MARK: - Lattice generation

private struct TestLattice {
    var edges: [LatticeEdge]
    var inputLength: Int
}

/// Drawn from a fixed pool and independent of position, so the same word can
/// appear at several positions — that is what exercises state merging and
/// text-level deduplication in both decoders.
private let wordCharacters: [Character] = Array(
    "的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事"
)

private func syntheticWord(span: Int, variant: Int) -> String {
    var word = ""
    for offset in 0..<span {
        let index = (variant &* 7 &+ span &* 13 &+ offset &* 3) % wordCharacters.count
        word.append(wordCharacters[index])
    }
    return word
}

/// Production-shaped random lattice: input length 2–8, 1–6 edges per
/// position, spans 1–3, mostly lexicon words with occasional Latin and name
/// edges. Positions occasionally emit nothing, so paths reaching them die
/// (dead-ends) and later positions may be reachable only by edges jumping
/// over (unreachable spans) — the decoder must survive both.
private func randomLattice(_ rng: inout SplitMix64) -> TestLattice {
    let inputLength = rng.int(in: 2...8)
    var edges: [LatticeEdge] = []
    for position in 0..<inputLength {
        if position > 0, rng.chance(0.12) { continue }
        for _ in 0..<rng.int(in: 1...6) {
            let span = rng.int(in: 1...min(3, inputLength - position))
            let end = position + span
            let roll = rng.double01()
            let text: String
            let reading: LatticeEdge.Reading
            if roll < 0.08 {
                let evidences: [ScoreModel.LatinEvidence] = [
                    .spelledOut, .curatedExpansion, .guessedExpansion,
                ]
                text = ["AI", "OK", "Code", "Vim"][rng.int(in: 0...3)]
                reading = .latin(evidences[rng.int(in: 0...2)])
            } else if roll < 0.14 {
                text = "名" + syntheticWord(span: span, variant: rng.int(in: 0...7))
                reading = .name(logProbability: -rng.double(in: 4.0...30.0))
            } else {
                text = syntheticWord(span: span, variant: rng.int(in: 0...7))
                let forms: [ScoreModel.TypingForm] = [.full, .full, .full, .mixed, .initials]
                reading = .lexicon(
                    weight: exp(rng.double(in: 0.0...14.0)),
                    form: forms[rng.int(in: 0...4)]
                )
            }
            edges.append(
                LatticeEdge(
                    start: position, end: end, text: text,
                    pinyin: "p\(position)e\(end)", reading: reading
                )
            )
        }
    }
    return TestLattice(edges: edges, inputLength: inputLength)
}

// MARK: - Hard invariants

/// Properties that must hold for every returned path no matter how much the
/// frontier cap pruned: descending score order, no duplicate texts, and each
/// path realised by an actual start→end edge chain whose recomputed score
/// matches the one reported.
private func verifyInvariants(
    _ paths: [LatticeDecoder.Path],
    in lattice: TestLattice,
    transition: (String, String) -> Double
) {
    for index in 1..<max(paths.count, 1) {
        #expect(
            paths[index - 1].score >= paths[index].score - 1e-9,
            "paths must be sorted by descending score"
        )
    }
    let texts = paths.map(\.text)
    #expect(Set(texts).count == texts.count, "duplicate texts in n-best")

    var edgesFrom = [[LatticeEdge]](repeating: [], count: lattice.inputLength + 1)
    for edge in lattice.edges where edge.start >= 0 && edge.end <= lattice.inputLength {
        edgesFrom[edge.start].append(edge)
    }
    for path in paths {
        #expect(path.words.count > 1, "single words are not sentences")
        #expect(path.words.count == path.weights.count)
        #expect(path.words.count == path.pinyin.count)
        #expect(path.segments == path.words.count)
        #expect(path.words.joined() == path.text)
        // Bound to a local first: #expect captures its operands, and the
        // non-escaping `transition` closure cannot cross into the macro.
        let realised = chainRealises(
            path, edgesFrom: edgesFrom, inputLength: lattice.inputLength,
            transition: transition
        )
        #expect(
            realised,
            "path \(path.text) has no start→end edge chain reproducing score \(path.score)"
        )
    }
}

/// True when some connected edge chain spells this path — same words, same
/// pinyin, same weights — and its recomputed score matches the reported one.
/// This is the anti-lying check: a decoder bug that mispropagates scores or
/// stitches disconnected states fails here even if the ranking looks fine.
private func chainRealises(
    _ path: LatticeDecoder.Path,
    edgesFrom: [[LatticeEdge]],
    inputLength: Int,
    transition: (String, String) -> Double
) -> Bool {
    func descend(position: Int, index: Int, previous: String, score: Double) -> Bool {
        if index == path.words.count {
            return position == inputLength && abs(score - path.score) <= 1e-9
        }
        guard position < inputLength else { return false }
        for edge in edgesFrom[position]
        where edge.text == path.words[index]
            && edge.pinyin == path.pinyin[index]
            && edge.weight == path.weights[index] {
            let step = edge.score(
                afterWord: previous,
                logTotalWeight: testLogTotalWeight,
                transition: transition
            )
            if descend(
                position: edge.end, index: index + 1,
                previous: edge.text, score: score + step
            ) {
                return true
            }
        }
        return false
    }
    return descend(position: 0, index: 0, previous: DictTrie.sentenceStart, score: 0)
}

// MARK: - Differential runs

private struct DifferentialStats {
    var compared = 0
    var top1Disagreements = 0
    var scoreLossSum = 0.0
    var overlapSum = 0.0
    /// Lattices whose top-5 *score sequences* differ beyond float noise.
    /// Text overlap alone can dip on exact ties (two Latin readings price
    /// identically, so equal-score paths pop in either order); a score
    /// sequence mismatch is real approximation, never tie shuffling.
    var top5ScoreMismatches = 0
    var latticeEmptyReferenceNot = 0

    var top1DisagreementRate: Double {
        compared > 0 ? Double(top1Disagreements) / Double(compared) : 0
    }
    var meanScoreLoss: Double {
        top1Disagreements > 0 ? scoreLossSum / Double(top1Disagreements) : 0
    }
    var meanTop5Overlap: Double {
        compared > 0 ? overlapSum / Double(compared) : 1
    }
}

private func compare(
    _ lattice: TestLattice,
    limit: Int,
    transition: (String, String) -> Double,
    into stats: inout DifferentialStats
) {
    let got = LatticeDecoder.nBest(
        edges: lattice.edges, inputLength: lattice.inputLength, limit: limit,
        logTotalWeight: testLogTotalWeight, transition: transition
    )
    let want = ReferenceDecoder.nBest(
        edges: lattice.edges, inputLength: lattice.inputLength, limit: limit,
        logTotalWeight: testLogTotalWeight, transition: transition
    )
    verifyInvariants(got, in: lattice, transition: transition)

    // The reference enumerates every chain, so it is empty exactly when no
    // multi-word path exists; the invariants above force `got` empty too.
    if want.isEmpty {
        #expect(got.isEmpty, "lattice decoder invented a path the lattice does not contain")
        return
    }
    guard let gotTop = got.first, let wantTop = want.first else {
        stats.latticeEmptyReferenceNot += 1
        return
    }
    stats.compared += 1
    // Text-insensitive on exact ties: equal-score paths may legitimately pop
    // in either order, and both decoders break those ties arbitrarily.
    if gotTop.text != wantTop.text, abs(gotTop.score - wantTop.score) > 1e-9 {
        stats.top1Disagreements += 1
        stats.scoreLossSum += wantTop.score - gotTop.score
    }
    let gotHead = got.prefix(5)
    let wantHead = want.prefix(5)
    if gotHead.count != wantHead.count
        || zip(gotHead, wantHead).contains(where: { abs($0.score - $1.score) > 1e-9 }) {
        stats.top5ScoreMismatches += 1
    }
    stats.overlapSum +=
        Double(Set(gotHead.map(\.text)).intersection(wantHead.map(\.text)).count)
        / Double(min(5, want.count))
}

@Suite("Decoder differential (vs exhaustive reference)")
struct DecoderDifferentialTests {

    /// Production-shaped lattices. With 1–6 edges per position and spans up
    /// to 3, at most 18 distinct last-word states can converge on a position,
    /// which is under `maxStatesPerPosition = 24` — the frontier cap never
    /// fires, so the decoder should be *exact* here, and the thresholds
    /// assert the measured fact rather than a hope.
    ///
    /// MEASURED (3000 lattices, seed 0x5EED_B111, 2646 with at least one
    /// sentence path): top-1 disagreement 0/2646 = 0.0%; top-5 score-sequence
    /// mismatches 0; lattice-empty-while-reference-not 0. Top-5 *text*
    /// overlap was 0.9994, and every deviation from 1.0 was an equal-score
    /// tie popping in a different order (two Latin readings price
    /// identically), which is why the assertions below are on scores, not
    /// texts. The decoder is measurably exact here, so the thresholds are
    /// the measurements themselves — zero tolerance.
    @Test("Random lattices under the state cap decode exactly")
    func randomLatticesMatchReference() {
        var rng = SplitMix64(seed: 0x5EED_B111)
        var stats = DifferentialStats()
        for _ in 0..<3000 {
            let lattice = randomLattice(&rng)
            compare(lattice, limit: 10, transition: syntheticTransition, into: &stats)
        }
        print(
            """
            [differential/random] compared=\(stats.compared) \
            top1Disagree=\(stats.top1Disagreements) \
            rate=\(stats.top1DisagreementRate) \
            meanScoreLoss=\(stats.meanScoreLoss) \
            top5Overlap=\(stats.meanTop5Overlap) \
            top5ScoreMismatch=\(stats.top5ScoreMismatches) \
            latticeEmptyRefNot=\(stats.latticeEmptyReferenceNot)
            """
        )
        #expect(stats.compared > 2000, "generator should produce mostly solvable lattices")
        #expect(stats.top1DisagreementRate == 0)
        #expect(stats.top5ScoreMismatches == 0)
        #expect(stats.latticeEmptyReferenceNot == 0)
    }

    /// Lattices built to blow through the frontier cap: 40 distinct words at
    /// position 0, so 40 last-word states compete at position 1 where only 24
    /// survive. Pruning ranks states by *prefix* score, so the way to lose
    /// the true best path is exclusive downstream advantage: an "idiom" chain
    /// whose first word has a weak unigram (pruned on prefix rank) but whose
    /// continuation is strongly predicted — the 工程院·院士 shape, which is
    /// precisely what the real bigram table rewards. Independent random
    /// transitions cannot produce this (a strong continuation is then as
    /// likely to hang off a surviving state), which is itself a finding:
    /// the cap only costs anything under correlated transition structure.
    ///
    /// MEASURED (400 lattices, seed 0x1D10_CA5E): top-1 disagreement
    /// 30/400 = 7.5%; mean score loss on disagreement 1.50 (natural-log
    /// probability); top-5 text overlap 0.939; top-5 score-sequence
    /// mismatches 95/400 = 23.75%. Deeper ranks suffer more than top-1
    /// because a pruned state silently deletes whole families of
    /// lower-ranked paths. Thresholds sit slightly above those measurements.
    @Test("Exceeding maxStatesPerPosition makes the decoder approximate")
    func denseLatticesShowPruningLoss() {
        var rng = SplitMix64(seed: 0x1D10_CA5E)
        var stats = DifferentialStats()
        let lattices = 400
        let inputLength = 3
        // Wide only where pruning is under test; narrow elsewhere keeps the
        // exhaustive reference affordable (40·12·12 ≈ 5.8k paths per lattice).
        let wordsAt = [40, 12, 12]
        for _ in 0..<lattices {
            var edges: [LatticeEdge] = []
            var texts: [[String]] = []
            for position in 0..<inputLength {
                var positionTexts: [String] = []
                for variant in 0..<wordsAt[position] {
                    // Offset by position so the same variant is a different
                    // word at each position; states must be genuinely distinct.
                    let index = (position &* 41 &+ variant) % wordCharacters.count
                    let text = String(wordCharacters[index])
                    positionTexts.append(text)
                    edges.append(
                        LatticeEdge(
                            start: position, end: position + 1, text: text,
                            pinyin: "p\(position)", reading: .lexicon(
                                weight: exp(rng.double(in: 0.0...14.0)),
                                form: .full
                            )
                        )
                    )
                }
                texts.append(positionTexts)
            }
            // Idiom chains: strong conditionals along a few specific
            // word sequences, nothing anywhere else.
            // Two idioms, not more: the true best path is the best idiom, and
            // pruning bites only when *that* idiom's first word ranks below
            // the cap on unigram prefix score. More idioms would mean the
            // best of them nearly always starts with a high-unigram word
            // that survives, hiding the effect being demonstrated.
            var conditionals: [String: Double] = [:]
            for _ in 0..<2 {
                let first = texts[0][rng.int(in: 0...wordsAt[0] - 1)]
                let second = texts[1][rng.int(in: 0...wordsAt[1] - 1)]
                let third = texts[2][rng.int(in: 0...wordsAt[2] - 1)]
                conditionals[first + "\u{1}" + second] = rng.double(in: 0.3...0.7)
                conditionals[second + "\u{1}" + third] = rng.double(in: 0.3...0.7)
            }
            let transition: (String, String) -> Double = { previous, next in
                conditionals[previous + "\u{1}" + next] ?? 0
            }
            let lattice = TestLattice(edges: edges, inputLength: inputLength)
            compare(lattice, limit: 10, transition: transition, into: &stats)
        }
        print(
            """
            [differential/dense] compared=\(stats.compared) \
            top1Disagree=\(stats.top1Disagreements) \
            rate=\(stats.top1DisagreementRate) \
            meanScoreLoss=\(stats.meanScoreLoss) \
            top5Overlap=\(stats.meanTop5Overlap) \
            top5ScoreMismatch=\(stats.top5ScoreMismatches) \
            latticeEmptyRefNot=\(stats.latticeEmptyReferenceNot)
            """
        )
        #expect(stats.compared == lattices)
        // Approximation must be visible here — a zero would mean the dense
        // construction stopped exercising the cap and the test lost its point.
        #expect(stats.top1Disagreements > 0)
        #expect(stats.top1DisagreementRate <= 0.10)  // measured 0.075
        #expect(stats.meanScoreLoss <= 2.5)          // measured 1.50
        #expect(stats.meanTop5Overlap >= 0.90)       // measured 0.939
        #expect(stats.latticeEmptyReferenceNot == 0)
    }
}
