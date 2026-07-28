import Foundation

/// The trainable half of candidate ranking.
///
/// The generative score in `ScoreModel` is principled but its components meet
/// through hand-set priors — the typing-form probabilities, the Latin
/// pseudo-frequencies, the literal prior. Each was swept on the development
/// set one at a time, which cannot capture interactions between them. This
/// replaces the final combination with a learned linear model over explicit
/// features:
///
///     S(candidate) = θ · features(candidate)
///
/// θ is trained offline (Tools/DataPipeline/train_ranker.py) with a listwise
/// softmax objective over real candidate lists, and shipped as versioned JSON.
/// Feature 0 is the whole generative score, and the built-in fallback is
/// θ = [1, 0, 0, …] — exactly the untrained behaviour — so a missing,
/// malformed, or version-mismatched weights file degrades to today's ranking
/// rather than to garbage.
public enum RankerModel {
    /// Order and meaning are frozen per schema version. Adding a feature means
    /// bumping the version, never reusing a slot.
    public static let featureNames: [String] = [
        "generative_score",       // 0: ScoreModel log-probability, the backbone
        "src_system",             // 1: whole-key lexicon word
        "src_sentence",           // 2: composed by the decoder
        "src_abbreviation",       // 3: whole-key abbreviation
        "src_name",               // 4: personal-name model
        "src_english",            // 5: Latin word or completion
        "src_literal",            // 6: the raw keystrokes
        "segments_log",           // 7: log(1+segments) for composed paths
        "candidate_length",       // 8: characters in the candidate
        "key_length",             // 9: letters typed
        "contains_latin",         // 10
        "han_length_ratio",       // 11: chars per key letter, Han only — see below
    ]
    public static let schemaVersion = 1

    public struct Weights: Sendable {
        public let values: [Double]
        public let version: Int
        public let trainedOn: String

        /// Reproduces the untrained engine exactly.
        public static let fallback = Weights(
            values: [1] + [Double](repeating: 0, count: featureNames.count - 1),
            version: schemaVersion,
            trainedOn: "builtin-fallback"
        )
    }

    public static func features(for candidate: Candidate, keyLength: Int) -> [Double] {
        var f = [Double](repeating: 0, count: featureNames.count)
        f[0] = candidate.score
        switch candidate.source {
        case .system: f[1] = 1
        case .sentence: f[2] = 1
        case .abbreviation: f[3] = 1
        case .name: f[4] = 1
        case .english: f[5] = 1
        case .literal: f[6] = 1
        case .learned: break
        case .corrected:
            // A typo-repaired reading behaves like the source that produced
            // it; the repair cost is already inside the generative score, so
            // no separate indicator is needed until training data contains
            // corrected positives to estimate one from.
            break
        }
        let segments = max(1, candidate.pinyin.split(separator: " ").count)
        f[7] = candidate.source == .sentence ? log(1 + Double(segments)) : 0
        f[8] = Double(candidate.text.count)
        f[9] = Double(keyLength)
        let hasLatin = candidate.text.contains(where: { $0.isASCII && $0.isLetter })
        f[10] = hasLatin ? 1 : 0
        // Characters-per-letter is a real signal for Han candidates (a path
        // averaging one character per keystroke is usually syllable-by-
        // syllable noise), but for Latin candidates the ratio is ~1 by
        // definition. Training data has no Latin positives, so an undivided
        // ratio feature turns into a hidden anti-Latin penalty — measured: it
        // buried AI and xswl. Scoping it to Han keeps the signal and removes
        // the bias.
        f[11] = (!hasLatin && keyLength > 0)
            ? Double(candidate.text.count) / Double(keyLength) : 0
        return f
    }

    public static func score(_ candidate: Candidate, keyLength: Int, weights: Weights) -> Double {
        let f = features(for: candidate, keyLength: keyLength)
        var total = 0.0
        for index in 0..<min(f.count, weights.values.count) {
            total += f[index] * weights.values[index]
        }
        return total
    }

    /// Loads weights, validating schema and shape. Every failure path lands on
    /// the fallback: the ranking model is an enhancement, never a dependency.
    public static func loadWeights(from url: URL?) -> Weights {
        guard let url,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schema_version"] as? Int,
              version == schemaVersion,
              let names = object["features"] as? [String],
              names == featureNames,
              let values = object["theta"] as? [Double],
              values.count == featureNames.count,
              values.allSatisfy({ $0.isFinite })
        else {
            return .fallback
        }
        return Weights(
            values: values,
            version: version,
            trainedOn: object["trained_on"] as? String ?? "unknown"
        )
    }

    /// Search order: an explicit override, the user's data directory, then the
    /// bundled resource, then the built-in fallback.
    public static func defaultWeights() -> Weights {
        if let override = ProcessInfo.processInfo.environment["BILING_RANKER_WEIGHTS"] {
            return loadWeights(from: URL(fileURLWithPath: override))
        }
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("BiLing/ranker-weights.json")
        if let support, FileManager.default.fileExists(atPath: support.path) {
            return loadWeights(from: support)
        }
        if let bundled = Bundle.module.url(forResource: "ranker-weights", withExtension: "json") {
            return loadWeights(from: bundled)
        }
        return .fallback
    }
}
