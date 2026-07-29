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
