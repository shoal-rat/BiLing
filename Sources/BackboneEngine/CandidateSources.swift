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

/// 简拼 and mixed-code readings of the whole key.
///
/// The whole key read as syllable initials (jldx → 吉林大学), or as a mix of
/// full and reduced syllables (jilindx). When the letters are also full
/// pinyin the interpretation is a long shot, so it sinks; when they are not
/// (jldx, zgrm), it carries the list together with curated Latin entries.
public struct AbbreviationSource: WholeKeyCandidateSource {
    let dictionary: DictTrie

    public init(dictionary: DictTrie) {
        self.dictionary = dictionary
    }

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        let key = request.key
        guard key.count <= 8 else { return [] }
        var results: [Candidate] = []
        for entry in dictionary.abbreviated(key, limit: 8) {
            results.append(
                Candidate(
                    text: entry.text,
                    pinyin: entry.displayPinyin,
                    source: .abbreviation,
                    consumed: key.count,
                    score: ScoreModel.segmentLogProbability(
                        weight: entry.weight,
                        logTotalWeight: request.logTotalWeight,
                        form: .initials
                    ) + ScoreModel.contextPromotion(
                        weight: entry.weight,
                        logTotalWeight: request.logTotalWeight,
                        conditional: request.contextConditional(entry.text)
                    )
                )
            )
        }
        for entry in dictionary.mixedCoded(key, limit: 6) {
            results.append(
                Candidate(
                    text: entry.text,
                    pinyin: entry.displayPinyin,
                    source: .abbreviation,
                    consumed: key.count,
                    score: ScoreModel.segmentLogProbability(
                        weight: entry.weight,
                        logTotalWeight: request.logTotalWeight,
                        form: .mixed
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

/// Whole-buffer personal names: a surname followed by one or two given-name
/// characters, generated as whole candidates rather than lattice edges.
///
/// A name covering the entire buffer is one segment, and the decoder drops
/// single-segment paths because they would duplicate exact dictionary
/// matches — so a name assembled in the lattice was silently discarded.
/// Emitting names here also keeps them out of the decoder's state budget,
/// where they were measured to evict genuine word paths and cost 3.8 points
/// of coverage.
///
/// Character fallback already makes names constructible, but it picks the
/// commonest character per syllable — `wangjianlin` yields 望见林 rather
/// than 王建林 — because nothing marks those characters as name usage. The
/// name model supplies exactly that signal, and it is applied only when the
/// whole buffer could be a name, which is how people type them.
public struct NameCandidateSource: WholeKeyCandidateSource {
    let dictionary: DictTrie
    let inventory: SyllableInventory

    public init(dictionary: DictTrie, inventory: SyllableInventory) {
        self.dictionary = dictionary
        self.inventory = inventory
    }

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        let key = request.key
        guard dictionary.hasNameModel, key.count <= 12 else { return [] }
        let segmenter = Segmenter(inventory: inventory)
        let syllables = segmenter.edges(in: key)
        guard !syllables.isEmpty else { return [] }
        let length = key.count
        var results: [Candidate] = []

        for surnameEdge in syllables[0] where surnameEdge.syllable != "'" {
            let surnames = dictionary.surnameCharacters(forSyllable: surnameEdge.syllable)
            guard !surnames.isEmpty, surnameEdge.end < syllables.count else { continue }
            for firstEdge in syllables[surnameEdge.end] where firstEdge.syllable != "'" {
                let firstGiven = dictionary.givenNameCharacters(
                    forSyllable: firstEdge.syllable, position: 1, limit: 4
                )
                guard !firstGiven.isEmpty else { continue }
                for surname in surnames {
                    for given in firstGiven {
                        if firstEdge.end == length {
                            results.append(
                                nameCandidate(
                                    text: surname.text + given.text,
                                    pinyin: "\(surnameEdge.syllable) \(firstEdge.syllable)",
                                    key: key,
                                    logProbability: surname.logp + given.logp
                                )
                            )
                        }
                        guard firstEdge.end < syllables.count else { continue }
                        for secondEdge in syllables[firstEdge.end]
                        where secondEdge.syllable != "'" && secondEdge.end == length {
                            for tail in dictionary.givenNameCharacters(
                                forSyllable: secondEdge.syllable, position: 2, limit: 4
                            ) {
                                results.append(
                                    nameCandidate(
                                        text: surname.text + given.text + tail.text,
                                        pinyin: "\(surnameEdge.syllable) \(firstEdge.syllable) \(secondEdge.syllable)",
                                        key: key,
                                        logProbability: surname.logp + given.logp + tail.logp
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        return results
    }

    private func nameCandidate(
        text: String,
        pinyin: String,
        key: String,
        logProbability: Double
    ) -> Candidate {
        Candidate(
            text: text,
            pinyin: pinyin,
            source: .name,
            consumed: key.count,
            score: logProbability
        )
    }
}

/// English/Latin readings of the whole key, from the curated lexicon.
public struct LatinCandidateSource: WholeKeyCandidateSource {
    let english: EnglishLexicon

    public init(english: EnglishLexicon) {
        self.english = english
    }

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        let key = request.key
        var results: [Candidate] = []

        // A fully typed curated key always surfaces its canonical form —
        // "claude" → Claude at the top in English mode; "ai" → AI as a lower
        // candidate because 爱 is a real word; "openai" → OpenAI ahead of
        // nonsense syllable stitches like 哦喷爱, because no real word owns
        // that key.
        if let display = english.exactDisplay(for: key) {
            // The letters spell a known term exactly. That is strong evidence
            // unless they also spell valid pinyin, where Chinese keeps priority.
            let score = ScoreModel.latinLogProbability(
                request.mode == .chinesePrimary ? .curatedExpansion : .spelledOut,
                logTotalWeight: request.logTotalWeight
            )
            results.append(
                Candidate(
                    text: display,
                    pinyin: key,
                    source: .english,
                    consumed: key.count,
                    score: score
                )
            )
        }

        if request.mode == .englishPrimary || request.mode == .chineseWithEnglish
            || request.mode == .literal {
            for (rank, word) in english.completions(for: key, limit: 4).enumerated() {
                results.append(
                    Candidate(
                        text: word,
                        pinyin: key,
                        source: .english,
                        consumed: key.count,
                        // Later completions are progressively weaker guesses.
                        score: ScoreModel.latinLogProbability(
                            .curatedExpansion,
                            logTotalWeight: request.logTotalWeight
                        ) + log(1.0 / Double(rank + 1))
                    )
                )
            }
        }
        return results
    }
}

/// The raw keystrokes, exactly as typed. Always present: Return commits
/// them, and users rely on that escape hatch.
public struct LiteralCandidateSource: WholeKeyCandidateSource {
    public init() {}

    public func candidates(for request: CandidateRequest) -> [Candidate] {
        [
            Candidate(
                text: request.rawInput,
                pinyin: request.key,
                source: .literal,
                consumed: request.key.count,
                score: request.mode == .literal
                    ? ScoreModel.literalIntended
                    : ScoreModel.literalLogProbability(length: request.key.count)
            )
        ]
    }
}
