import BackboneEngine
import Foundation
import IPCProtocol
import LLMRanker

/// Corpus-driven accuracy harness.
///
/// Reports top-1 / top-5 accuracy and MRR over a labelled TSV, per category
/// and overall, so scoring changes are judged by a number rather than by
/// whether a favourite example happens to pass.
enum Evaluate {
    struct Row {
        let category: String
        let context: String
        let pinyin: String
        let expected: String
    }

    /// Chinese/Latin boundary spacing is a display convention, not part of the
    /// reading, so it is ignored when matching.
    static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .lowercased()
    }

    static func parse(_ url: URL) throws -> [Row] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .compactMap { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count >= 4 else { return nil }
                return Row(
                    category: fields[0],
                    context: fields[1] == "-" ? "" : fields[1],
                    pinyin: fields[2],
                    expected: fields[3]
                )
            }
    }

    struct Outcome {
        let row: Row
        let rank: Int?          // 1-based; nil when absent entirely
        let top: String
        let milliseconds: Double
    }

    /// Writes one JSON line per corpus item: the candidate list with feature
    /// vectors and which candidate matches the target. This is the training
    /// set for the listwise ranker — real lists the engine actually produced,
    /// hard negatives included by construction.
    static func dumpFeatures(corpus: URL, useContext: Bool) throws {
        let rows = try parse(corpus)
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
        EnglishLexicon.shared.warm()
        var emitted = 0
        for row in rows {
            let context = useContext ? row.context : ""
            let candidates = engine.candidates(for: row.pinyin, context: context).candidates
            let target = normalise(row.expected)
            guard let positive = candidates.firstIndex(where: { normalise($0.text) == target })
            else { continue }  // uncovered items teach the ranker nothing
            let list: [[String: Any]] = candidates.prefix(40).map { candidate in
                [
                    "features": RankerModel.features(for: candidate, keyLength: row.pinyin.count),
                    "text": candidate.text,
                ]
            }
            guard positive < list.count else { continue }
            let record: [String: Any] = [
                "keys": row.pinyin,
                "positive_index": positive,
                "candidates": list,
            ]
            let data = try JSONSerialization.data(withJSONObject: record)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            emitted += 1
        }
        FileHandle.standardError.write(Data("emitted \(emitted) lists of \(rows.count) items\n".utf8))
    }

    static func run(
        corpus: URL,
        ranker: QwenRanker?,
        useContext: Bool,
        tolerance: ToleranceOptions = .off
    ) throws {
        let rows = try parse(corpus)
        let engine = try PinyinEngine(
            dictionary: .bundled(),
            learningStore: MemoryLearningStore(),
            tolerance: tolerance
        )
        EnglishLexicon.shared.warm()
        var outcomes: [Outcome] = []
        var invocations = 0
        var gatedOut = 0
        let clock = ContinuousClock()

        for row in rows {
            let context = useContext ? row.context : ""
            let start = clock.now
            var candidates = engine.candidates(for: row.pinyin, context: context).candidates
            let gateOpen = ScoreModel.shouldInvokeModel(
                topScore: candidates.first?.score ?? 0,
                secondScore: candidates.count > 1 ? candidates[1].score : nil
            )
            if gateOpen { invocations += 1 } else { gatedOut += 1 }
            if let ranker, gateOpen {
                let request = RankRequest(
                    clientID: UUID(),
                    generation: 1,
                    input: row.pinyin,
                    committedContext: context,
                    candidates: candidates.prefix(30).map(\.text)
                )
                if let reply = try? runBlocking({ try await ranker.rank(request) }) {
                    candidates = CandidateBlender.blend(
                        candidates,
                        orderedCandidates: reply.orderedCandidates,
                        scores: reply.scores,
                        hasContext: !context.isEmpty
                    )
                }
            }
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            let target = normalise(row.expected)
            let rank = candidates.firstIndex { normalise($0.text) == target }.map { $0 + 1 }
            outcomes.append(
                Outcome(
                    row: row,
                    rank: rank,
                    top: candidates.first?.text ?? "",
                    milliseconds: ms
                )
            )
        }
        report(outcomes)
        if invocations + gatedOut > 0 {
            let rate = 100 * Double(invocations) / Double(invocations + gatedOut)
            print(String(format: "\nmodel gate: invoked %d of %d items (%.1f%%)",
                         invocations, invocations + gatedOut, rate))
        }
    }

    static func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private static func report(_ outcomes: [Outcome]) {
        func line(_ label: String, _ items: [Outcome]) {
            guard !items.isEmpty else { return }
            let top1 = items.filter { $0.rank == 1 }.count
            let top5 = items.filter { ($0.rank ?? .max) <= 5 }.count
            // Coverage separates the two failures that need opposite fixes:
            // a candidate that was never generated is a search/lexicon problem,
            // one that was generated but ranked low is a scoring problem.
            let covered = items.filter { $0.rank != nil }.count
            let mrr = items.reduce(0.0) { $0 + ($1.rank.map { 1.0 / Double($0) } ?? 0) }
                / Double(items.count)
            let latencies = items.map(\.milliseconds).sorted()
            let median = latencies[latencies.count / 2]
            let p95 = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
            print(
                String(
                    format: "%-13@ n=%-4d top1 %5.1f%%  top5 %5.1f%%  cover %5.1f%%  MRR %.3f  median %6.1f ms  p95 %6.1f ms",
                    label as NSString,
                    items.count,
                    100 * Double(top1) / Double(items.count),
                    100 * Double(top5) / Double(items.count),
                    100 * Double(covered) / Double(items.count),
                    mrr,
                    median,
                    p95
                )
            )
        }

        print("")
        for category in Array(NSOrderedSet(array: outcomes.map(\.row.category)).array as! [String]) {
            line(category, outcomes.filter { $0.row.category == category })
        }
        print(String(repeating: "-", count: 96))
        line("OVERALL", outcomes)

        let misses = outcomes.filter { $0.rank != 1 }
        guard !misses.isEmpty else { return }
        print("\nMisses (\(misses.count)):")
        for miss in misses {
            let rank = miss.rank.map(String.init) ?? "absent"
            print("  \(miss.row.pinyin)")
            print("      want \(miss.row.expected)   got \(miss.top)   rank \(rank)")
        }
    }
}
