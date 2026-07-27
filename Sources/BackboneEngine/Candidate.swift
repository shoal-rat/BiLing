import Foundation
import PinyinLattice

public enum CandidateSource: String, Codable, Sendable {
    case system
    case learned
    case sentence
    case abbreviation
    case english
    case literal
}

public struct Candidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(text)\u{1f}\(pinyin)" }
    public let text: String
    public let pinyin: String
    public let source: CandidateSource
    public let consumed: Int
    public var score: Double

    public init(
        text: String,
        pinyin: String,
        source: CandidateSource,
        consumed: Int,
        score: Double
    ) {
        self.text = text
        self.pinyin = pinyin
        self.source = source
        self.consumed = consumed
        self.score = score
    }
}

public struct EngineResult: Sendable {
    public let input: String
    public let mode: PinyinMode
    public let candidates: [Candidate]
    public let generation: UInt64
}

/// Merges Qwen's language-model scores into the deterministic candidate list.
/// The input method and the diagnostic CLI share this exact function, so what
/// `biling-cli` prints is the ranking a user would see while typing.
public enum CandidateBlender {
    public static func blend(
        _ candidates: [Candidate],
        orderedCandidates: [String],
        scores: [String: Double],
        hasContext: Bool
    ) -> [Candidate] {
        // With committed context the model has real evidence and gets a strong
        // vote. Cold, its preference is mostly style (辣鸡 over 垃圾), so corpus
        // frequency keeps the upper hand.
        // The model may only *promote* candidates it likes better than the
        // lexicon's own first choice; it can never push that choice down by an
        // arbitrary amount. Where the lexicon is already decided — a common
        // single syllable, a Latin key that is simply what the user typed —
        // there is nothing for the model to win and plenty to lose, and this
        // makes that structural rather than a hope that the weight is small.
        // (An n-best analogue of internal-LM subtraction: score against the
        // prior's pick instead of against zero.)
        let reference = candidates.first.flatMap { scores[$0.text] } ?? 0
        var byText = Dictionary(
            candidates.map { ($0.text, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rescored: [Candidate] = []
        for text in orderedCandidates {
            guard var candidate = byText.removeValue(forKey: text) else { continue }
            let delta = max(0, (scores[text] ?? reference) - reference)
            candidate.score += delta * ScoreModel.languageModelWeight(
                hasContext: hasContext,
                candidateLength: candidate.text.count
            )
            rescored.append(candidate)
        }
        rescored.sort { $0.score > $1.score }
        rescored.append(contentsOf: candidates.filter { byText[$0.text] != nil })
        return rescored
    }
}
