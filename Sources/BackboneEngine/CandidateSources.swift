import Foundation
import PinyinLattice

/// The per-keystroke facts a whole-key candidate producer works from.
///
/// Built once per call to `PinyinEngine.candidates(for:context:generation:)`
/// and handed to every source, so all producers price against the same
/// normalized key, the same mode reading, and the same lexicon denominator.
/// The fields are the minimal honest set: each one is used by at least one
/// producer, and nothing here is derivable state a producer could compute
/// differently on its own.
public struct CandidateRequest {
    /// The keystrokes exactly as the client delivered them, before
    /// normalization. The literal candidate commits this string, because
    /// Return must reproduce what the user actually typed.
    public let rawInput: String

    /// The normalized lookup key every dictionary and lexicon query uses.
    public let key: String

    /// Script mode inferred from the raw input, read once per keystroke.
    public let mode: PinyinMode

    /// The lexicon's log total weight, read once so every producer prices
    /// probabilities against the same denominator within one candidate list.
    public let logTotalWeight: Double

    /// Bigram evidence that a candidate follows the last committed word.
    /// Returns 0 whenever there is no usable context, which leaves every
    /// score untouched.
    public let contextConditional: (String) -> Double

    public init(
        rawInput: String,
        key: String,
        mode: PinyinMode,
        logTotalWeight: Double,
        contextConditional: @escaping (String) -> Double
    ) {
        self.rawInput = rawInput
        self.key = key
        self.mode = mode
        self.logTotalWeight = logTotalWeight
        self.contextConditional = contextConditional
    }
}

/// A producer of candidates that each cover the *whole* typed key.
///
/// Every conforming type reads the buffer as one unit — a learned entry, a
/// lexicon word, an abbreviation expansion, a personal name, a Latin term,
/// or the raw keystrokes. What they have in common is the shape of the
/// claim: one candidate, consuming the entire key, priced independently of
/// any segmentation. The engine merges their outputs under a single dedup
/// policy, so a source only proposes; it never decides.
///
/// The sentence lattice is deliberately *not* behind this protocol: it
/// produces multi-segment paths whose admission depends on how each path
/// read the keystrokes (exact, fuzzy, typo-repaired — harvest-class rules),
/// not whole-key candidates. Forcing one protocol over both would flatten
/// the type distinction that keeps tolerant admission honest.
public protocol WholeKeyCandidateSource {
    func candidates(for request: CandidateRequest) -> [Candidate]
}

/// Words the user has previously chosen for this exact key, rescored from
/// their decayed selection counts into the shared log-probability space.
public struct LearnedCandidateSource: WholeKeyCandidateSource {
    let learningStore: any LearningStore
    let dictionary: DictTrie

    public init(learningStore: any LearningStore, dictionary: DictTrie) {
        self.learningStore = learningStore
        self.dictionary = dictionary
    }

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        var results: [Candidate] = []
        for var learned in learningStore.candidates(for: request.key) {
            learned.score = ScoreModel.learnedLogProbability(
                decayedCount: learned.score,
                logMaxWeight: dictionary.logMaxWeight,
                logTotalWeight: request.logTotalWeight
            )
            results.append(learned)
        }
        return results
    }
}

/// Lexicon words whose full spelling covers the entire key.
public struct LexiconWholeKeySource: WholeKeyCandidateSource {
    let dictionary: DictTrie

    public init(dictionary: DictTrie) {
        self.dictionary = dictionary
    }

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        var results: [Candidate] = []
        for entry in dictionary.exact(request.key, limit: 240) {
            // One word covering the whole key, spelled out in full: the single
            // most likely story there is. No length bonus is needed — a rival
            // multi-word stitch pays the segment cost for each extra word.
            results.append(
                Candidate(
                    text: entry.text,
                    pinyin: entry.displayPinyin,
                    source: .system,
                    consumed: request.key.count,
                    score: ScoreModel.segmentLogProbability(
                        weight: entry.weight,
                        logTotalWeight: request.logTotalWeight,
                        form: .full
                    ) + ScoreModel.contextPromotion(
                        weight: entry.weight,
                        logTotalWeight: request.logTotalWeight,
                        conditional: request.contextConditional(entry.text)
                    )
                )
            )
        }
        return results
    }
}
