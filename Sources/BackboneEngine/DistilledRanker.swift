import Foundation

/// Runtime for a compact reranker distilled from the Qwen teacher — a small
/// MLP over the RankerModel feature vector, blended promotion-only exactly as
/// the teacher itself is.
///
/// No weights ship today, deliberately: every training run to date lands
/// within noise of the deterministic baseline on holdout, and the trainer
/// (`Tools/DataPipeline/distill_ranker.py`) refuses to export a model that
/// cannot prove itself — the 12 features are too coarse a bottleneck for the
/// teacher's text-level knowledge. The forward pass, loader, and blend are
/// tested and dormant: a future export drops in as one JSON file, found via
/// `BILING_DISTILLED_PATH`, Application Support, or the bundle.
///
/// A plain Swift forward pass, not Core ML: at a few hundred parameters the
/// arithmetic is ~1 µs, far below Core ML's per-request dispatch overhead,
/// and it keeps the model file a human-readable artefact of the trainer.
public struct DistilledRanker: Sendable {
    public let inputWeights: [[Double]]   // [feature][hidden]
    public let inputBias: [Double]
    public let outputWeights: [Double]
    public let outputBias: Double
    public let featureMean: [Double]
    public let featureStd: [Double]
    /// Promotion weight, swept by the trainer on its train split.
    public let blendWeight: Double

    public static let shared: DistilledRanker? = load()

    static func load() -> DistilledRanker? {
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["BILING_DISTILLED_PATH"].map(URL.init(fileURLWithPath:)),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("BiLing/distilled-ranker.json"),
            Bundle.module.url(forResource: "distilled-ranker", withExtension: "json"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let ranker = try? load(from: url) { return ranker }
        }
        return nil
    }

    static func load(from url: URL) throws -> DistilledRanker? {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "biling-distilled-ranker",
              object["version"] as? Int == 1,
              let featureCount = object["feature_count"] as? Int,
              featureCount == RankerModel.featureNames.count,
              let hidden = object["hidden"] as? Int,
              let w1 = object["w1"] as? [[Double]],
              let b1 = object["b1"] as? [Double],
              let w2 = object["w2"] as? [Double],
              let b2 = object["b2"] as? Double,
              let mean = object["feature_mean"] as? [Double],
              let std = object["feature_std"] as? [Double],
              let lambda = object["lambda"] as? Double,
              w1.count == featureCount, w1.allSatisfy({ $0.count == hidden }),
              b1.count == hidden, w2.count == hidden,
              mean.count == featureCount, std.count == featureCount,
              std.allSatisfy({ $0 > 0 }), lambda > 0, lambda.isFinite,
              (w1.flatMap { $0 } + b1 + w2 + mean + std + [b2]).allSatisfy(\.isFinite)
        else { return nil }
        return DistilledRanker(
            inputWeights: w1, inputBias: b1,
            outputWeights: w2, outputBias: b2,
            featureMean: mean, featureStd: std,
            blendWeight: lambda
        )
    }

    public func score(features: [Double]) -> Double {
        precondition(features.count == featureMean.count)
        let hiddenCount = inputBias.count
        var hidden = inputBias
        for featureIndex in 0..<features.count {
            let normalised = (features[featureIndex] - featureMean[featureIndex]) / featureStd[featureIndex]
            guard normalised != 0 else { continue }
            let row = inputWeights[featureIndex]
            for hiddenIndex in 0..<hiddenCount {
                hidden[hiddenIndex] += normalised * row[hiddenIndex]
            }
        }
        var output = outputBias
        for hiddenIndex in 0..<hiddenCount where hidden[hiddenIndex] > 0 {
            output += hidden[hiddenIndex] * outputWeights[hiddenIndex]
        }
        return output
    }

    /// Promotion-only rescoring: candidates the student prefers to the
    /// current leader gain the difference (weighted); nothing is demoted the
    /// student wasn't asked about. Mirrors `blended_top1` in the trainer.
    public func rescored(_ candidates: [Candidate], keyLength: Int) -> [Candidate] {
        guard let leader = candidates.first else { return candidates }
        let leaderScore = score(features: RankerModel.features(for: leader, keyLength: keyLength))
        var output = candidates
        for index in output.indices.dropFirst() {
            let student = score(
                features: RankerModel.features(for: output[index], keyLength: keyLength)
            )
            output[index].score += blendWeight * max(0, student - leaderScore)
        }
        return output.sorted { $0.score > $1.score }
    }
}
