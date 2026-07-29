import Foundation

/// Learned replacement for the fixed 3.0-nat invocation margin.
///
/// The margin heuristic asks one question — how far ahead is the leader? The
/// list knows more than that: how the mass is spread below the leader, and how
/// many candidates crowd the gap. This logistic model was calibrated on
/// held-out derived-corpus lists (`Tools/DataPipeline/distill_ranker.py`) to
/// estimate P(the deterministic top-1 is wrong): Brier 0.143 against a 0.231
/// base rate. Routing on it skips the model on ~35% of lists at a measured
/// worst-case cost of 2.1% skipped-but-wrong — an upper bound, since the model
/// does not fix every list it sees.
///
/// The gate degrades, never breaks: an absent or malformed file falls back to
/// the margin rule, so shipping without the JSON reproduces pre-gate
/// behaviour exactly.
public struct ConfidenceGate: Sendable {
    public let weights: [Double]
    public let bias: Double
    public let featureMean: [Double]
    public let featureStd: [Double]

    /// Route to the model when P(top-1 wrong) reaches this. Calibrated on
    /// derived-dev (Docs/results/gate-calibration.txt); overridable for
    /// calibration sweeps via BILING_GATE_THRESHOLD.
    public static let invocationThreshold: Double = {
        if let raw = ProcessInfo.processInfo.environment["BILING_GATE_THRESHOLD"],
           let value = Double(raw), value > 0, value < 1 {
            return value
        }
        return EngineConfig.shared.gateThreshold
    }()

    /// Feature lists longer than the training dump's truncation would shift
    /// the candidate-count feature off its calibrated scale.
    private static let listCap = 40

    public static let shared: ConfidenceGate? = load()

    static func load() -> ConfidenceGate? {
        // A/B escape hatch: force the margin fallback so calibration runs can
        // measure the learned gate against the rule it replaced.
        if ProcessInfo.processInfo.environment["BILING_GATE_DISABLE"] == "1" { return nil }
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["BILING_GATE_PATH"].map(URL.init(fileURLWithPath:)),
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("BiLing/confidence-gate.json"),
            Bundle.module.url(forResource: "confidence-gate", withExtension: "json"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let gate = try? load(from: url) { return gate }
        }
        return nil
    }

    /// Every validation failure returns nil rather than throwing detail: a
    /// gate that cannot be trusted entirely is not partially trusted.
    static func load(from url: URL) throws -> ConfidenceGate? {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "biling-confidence-gate",
              object["version"] as? Int == 1,
              let weights = object["w"] as? [Double],
              let bias = object["b"] as? Double,
              let mean = object["mean"] as? [Double],
              let std = object["std"] as? [Double],
              weights.count == 4, mean.count == 4, std.count == 4,
              (weights + mean + std + [bias]).allSatisfy(\.isFinite),
              std.allSatisfy({ $0 > 0 })
        else { return nil }
        return ConfidenceGate(weights: weights, bias: bias, featureMean: mean, featureStd: std)
    }

    /// P(deterministic top-1 is wrong), from the sorted score list. Must stay
    /// feature-for-feature identical to `gate_features` in the trainer.
    public func probabilityWrong(sortedScores: [Double]) -> Double {
        let scores = Array(sortedScores.prefix(Self.listCap))
        guard let top = scores.first else { return 1 }
        let margin = scores.count > 1 ? top - scores[1] : 20.0
        let head = scores.prefix(8)
        let peak = head.max() ?? 0
        let exponentials = head.map { exp($0 - peak) }
        let total = exponentials.reduce(0, +)
        let entropy = -exponentials.reduce(0.0) { sum, value in
            let p = value / total
            return sum + p * log(p + 1e-12)
        }
        let spread = top - scores[min(4, scores.count - 1)]
        let raw = [margin, entropy, spread, log(1 + Double(scores.count))]
        var logit = bias
        for index in 0..<4 {
            logit += weights[index] * (raw[index] - featureMean[index]) / featureStd[index]
        }
        return 1 / (1 + exp(-logit))
    }

    /// The one call sites use. Falls back to the margin rule when no
    /// calibrated gate is available.
    public static func shouldInvokeModel(sortedScores: [Double]) -> Bool {
        if let gate = shared {
            return gate.probabilityWrong(sortedScores: sortedScores) >= invocationThreshold
        }
        return ScoreModel.shouldInvokeModel(
            topScore: sortedScores.first ?? 0,
            secondScore: sortedScores.count > 1 ? sortedScores[1] : nil
        )
    }
}
