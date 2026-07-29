import BackboneEngine
import Foundation
import InputSessionCore
import IPCProtocol
import LLMRanker
import os.signpost

/// Deterministic keystroke replay.
///
/// Accuracy evaluation asks "given the whole buffer, is the answer first?".
/// That is not what a person experiences. They type one letter at a time, and
/// what matters is whether candidates appear promptly after *each* keystroke,
/// whether the list stops jumping around as they go, and how much work the
/// machine does to keep up. This replays a corpus letter by letter and records
/// exactly that.
///
/// Every interval is also emitted as an `os_signpost`, so the same run can be
/// opened in Instruments to attribute time and energy without changing the
/// code path being measured.
enum ReplayBenchmark {
    private static let log = OSLog(
        subsystem: "com.biling.inputmethod.BiLing",
        category: .pointsOfInterest
    )

    struct Sample {
        let prefixLength: Int
        let candidateCount: Int
        let topCandidate: String
        let milliseconds: Double
    }

    struct Summary {
        let keystrokes: Int
        let latencies: [Double]
        /// How often the first candidate changed between consecutive
        /// keystrokes, excluding the changes caused by the buffer growing into
        /// a genuinely different word. High churn is what makes a candidate
        /// window feel unstable to read.
        let topChanges: Int
        let emptyResults: Int
    }

    static func run(
        corpus: URL,
        limit: Int,
        ranker: QwenRanker?,
        useContext: Bool,
        stability: Bool = false
    ) throws {
        if stability {
            try runStabilityComparison(
                corpus: corpus,
                limit: limit,
                ranker: ranker,
                useContext: useContext
            )
            return
        }
        let rows = try Evaluate.parse(corpus).prefix(limit)
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
        EnglishLexicon.shared.warm()

        var latencies: [Double] = []
        var churn = 0
        var keystrokes = 0
        var empties = 0
        var modelCalls = 0
        let clock = ContinuousClock()

        for row in rows {
            let context = useContext ? row.context : ""
            var previousTop = ""
            let letters = Array(row.pinyin)
            // Replay the buffer growing one letter at a time, which is the only
            // way the per-keystroke cost and the instability between keystrokes
            // become visible at all.
            for count in 1...letters.count {
                let prefix = String(letters[0..<count])
                let signpostID = OSSignpostID(log: log)
                os_signpost(.begin, log: log, name: "keystroke", signpostID: signpostID,
                            "len=%d", count)

                let start = clock.now
                var candidates = engine.candidates(for: prefix, context: context).candidates
                if let ranker, count == letters.count {
                    // The model runs where the real engine would let it: on a
                    // settled buffer, not on every letter.
                    let request = RankRequest(
                        clientID: UUID(),
                        generation: UInt64(count),
                        input: prefix,
                        committedContext: context,
                        candidates: candidates.prefix(30).map(\.text)
                    )
                    if let reply = (try? Evaluate.runBlocking({ try await ranker.rank(request) })) ?? nil {
                        modelCalls += 1
                        candidates = CandidateBlender.blend(
                            candidates,
                            orderedCandidates: reply.orderedCandidates,
                            scores: reply.scores,
                            hasContext: !context.isEmpty
                        )
                    }
                }
                let elapsed = start.duration(to: clock.now)
                os_signpost(.end, log: log, name: "keystroke", signpostID: signpostID,
                            "n=%d", candidates.count)

                let milliseconds = Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
                latencies.append(milliseconds)
                keystrokes += 1
                let top = candidates.first?.text ?? ""
                if top.isEmpty { empties += 1 }
                if count > 1, top != previousTop { churn += 1 }
                previousTop = top
            }
        }

        report(
            Summary(
                keystrokes: keystrokes,
                latencies: latencies,
                topChanges: churn,
                emptyResults: empties
            ),
            modelCalls: modelCalls,
            items: rows.count
        )
    }

    private static func report(_ summary: Summary, modelCalls: Int, items: Int) {
        let sorted = summary.latencies.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int(Double(sorted.count) * fraction))
            return sorted[index]
        }
        let total = sorted.reduce(0, +)
        print("""

        Replay over \(items) items, \(summary.keystrokes) keystrokes

          per-keystroke latency
            p50            \(String(format: "%7.2f ms", percentile(0.50)))
            p95            \(String(format: "%7.2f ms", percentile(0.95)))
            p99            \(String(format: "%7.2f ms", percentile(0.99)))
            max            \(String(format: "%7.2f ms", sorted.last ?? 0))
            mean           \(String(format: "%7.2f ms", total / Double(max(1, sorted.count))))

          work
            model calls    \(modelCalls) (\(String(format: "%.2f", Double(modelCalls) / Double(max(1, summary.keystrokes)))) per keystroke)
            empty results  \(summary.emptyResults)

          stability
            top-1 changes  \(summary.topChanges) over \(summary.keystrokes - items) transitions \
        (\(String(format: "%.1f%%", 100 * Double(summary.topChanges) / Double(max(1, summary.keystrokes - items)))))

        Churn counts every change of the first candidate as the buffer grows.
        Some of it is unavoidable and correct — the answer for "ni" should not
        be the answer for "nihao" — so this is a number to track across changes,
        not to minimise blindly.
        """)
    }

    // MARK: - Stability A/B

    /// What one pipeline showed the simulated user, and how often it moved.
    private struct PipelineStats {
        /// The first candidate changed between consecutive keystrokes.
        var keystrokeChurn = 0
        /// The first candidate changed when the asynchronous rescoring
        /// landed on an already-visible list — the mid-read flip a plain
        /// keystroke count never sees.
        var rescoreFlips = 0
        /// The final keystroke's first candidate matched the labelled answer.
        var finalTopCorrect = 0
    }

    /// Replays the corpus through two pipelines fed identical inputs: the
    /// raw lists as the engine and reranker produce them, and the same lists
    /// filtered through `CandidateStabilityController` — what the user would
    /// see with stabilisation on. Same rows, same candidates, same model
    /// replies, so any difference in the numbers is the controller's doing.
    private static func runStabilityComparison(
        corpus: URL,
        limit: Int,
        ranker: QwenRanker?,
        useContext: Bool
    ) throws {
        let rows = try Evaluate.parse(corpus).prefix(limit)
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
        EnglishLexicon.shared.warm()

        var raw = PipelineStats()
        var stabilised = PipelineStats()
        var keystrokes = 0
        var modelCalls = 0
        var finalDivergence = 0

        for row in rows {
            let context = useContext ? row.context : ""
            // One controller per composition, exactly as the input method
            // holds one per composition between commits.
            var controller = CandidateStabilityController()
            var rawShown: [Candidate] = []
            var stabShown: [Candidate] = []
            var previousRawTop = ""
            var previousStabTop = ""
            let letters = Array(row.pinyin)

            for count in 1...letters.count {
                let prefix = String(letters[0..<count])
                keystrokes += 1
                let deterministic = engine.candidates(for: prefix, context: context).candidates

                rawShown = deterministic
                controller.keystroke(buffer: prefix)
                stabShown = controller.resolve(
                    shown: stabShown,
                    proposed: deterministic,
                    update: .keystroke,
                    id: \.text,
                    score: \.score
                )

                if count > 1, (rawShown.first?.text ?? "") != previousRawTop {
                    raw.keystrokeChurn += 1
                }
                if count > 1, (stabShown.first?.text ?? "") != previousStabTop {
                    stabilised.keystrokeChurn += 1
                }

                if let ranker, count == letters.count {
                    // The model runs where the real engine would let it: on a
                    // settled buffer. Its reply reaches both pipelines as the
                    // same asynchronous update to an already-visible list.
                    let request = RankRequest(
                        clientID: UUID(),
                        generation: UInt64(count),
                        input: prefix,
                        committedContext: context,
                        candidates: deterministic.prefix(30).map(\.text)
                    )
                    if let reply = try? Evaluate.runBlocking({ try await ranker.rank(request) }) {
                        modelCalls += 1
                        let blended = CandidateBlender.blend(
                            deterministic,
                            orderedCandidates: reply.orderedCandidates,
                            scores: reply.scores,
                            hasContext: !context.isEmpty
                        )
                        if blended.first?.text != rawShown.first?.text {
                            raw.rescoreFlips += 1
                            if ProcessInfo.processInfo.environment["BILING_FLIP_DEBUG"] != nil,
                               let newTop = blended.first,
                               let oldTop = blended.first(where: { $0.text == rawShown.first?.text }) {
                                let target = Evaluate.normalise(row.expected)
                                let verdict = Evaluate.normalise(newTop.text) == target
                                    ? "flip-correct"
                                    : (Evaluate.normalise(oldTop.text) == target ? "flip-wrong" : "flip-neither")
                                FileHandle.standardError.write(Data(
                                    "flip \(row.pinyin): \(oldTop.text) -> \(newTop.text) gain \(String(format: "%.3f", newTop.score - oldTop.score)) nats [\(verdict)]\n".utf8
                                ))
                            }
                        }
                        rawShown = blended
                        let resolved = controller.resolve(
                            shown: stabShown,
                            proposed: blended,
                            update: .asyncRescore,
                            id: \.text,
                            score: \.score
                        )
                        if resolved.first?.text != stabShown.first?.text {
                            stabilised.rescoreFlips += 1
                        }
                        stabShown = resolved
                    }
                }

                previousRawTop = rawShown.first?.text ?? ""
                previousStabTop = stabShown.first?.text ?? ""
            }

            let target = Evaluate.normalise(row.expected)
            if Evaluate.normalise(previousRawTop) == target { raw.finalTopCorrect += 1 }
            if Evaluate.normalise(previousStabTop) == target { stabilised.finalTopCorrect += 1 }
            if previousRawTop != previousStabTop { finalDivergence += 1 }
        }

        reportComparison(
            raw: raw,
            stabilised: stabilised,
            items: rows.count,
            keystrokes: keystrokes,
            modelCalls: modelCalls,
            finalDivergence: finalDivergence
        )
    }

    private static func reportComparison(
        raw: PipelineStats,
        stabilised: PipelineStats,
        items: Int,
        keystrokes: Int,
        modelCalls: Int,
        finalDivergence: Int
    ) {
        let transitions = max(1, keystrokes - items)
        let parameters = CandidateStabilityController.Parameters()
        func percent(_ part: Int, _ whole: Int) -> String {
            String(format: "%.1f%%", 100 * Double(part) / Double(max(1, whole)))
        }
        func pair(_ rawValue: String, _ stabValue: String) -> String {
            rawValue.padding(toLength: max(23, rawValue.count + 1), withPad: " ", startingAt: 0)
                + stabValue
        }
        print("""

        Replay over \(items) items, \(keystrokes) keystrokes — raw vs stabilised
        (identical inputs; \(modelCalls) model calls shared by both pipelines)

          churn seen by the user             raw                    stabilised
            keystroke top-1 changes          \(pair("\(raw.keystrokeChurn)/\(transitions) (\(percent(raw.keystrokeChurn, transitions)))", "\(stabilised.keystrokeChurn)/\(transitions) (\(percent(stabilised.keystrokeChurn, transitions)))"))
            rescoring top-1 flips            \(pair("\(raw.rescoreFlips) of \(modelCalls)", "\(stabilised.rescoreFlips) of \(modelCalls)"))
            total top-1 movements            \(pair("\(raw.keystrokeChurn + raw.rescoreFlips)", "\(stabilised.keystrokeChurn + stabilised.rescoreFlips)"))

          outcome at the final keystroke
            top-1 accuracy                   \(pair(percent(raw.finalTopCorrect, items), percent(stabilised.finalTopCorrect, items)))
            final top-1 divergence           \(finalDivergence) of \(items) items

        Stability parameters: negligible gain \(parameters.negligibleGainThreshold) nats, \
        re-promotion margin \(parameters.repromotionMargin) nats.
        Keystroke churn counts a changed first candidate between consecutive
        keystrokes; rescoring flips count the first candidate changing in
        place when the model's asynchronous reply lands on a visible list.
        """)
    }
}
