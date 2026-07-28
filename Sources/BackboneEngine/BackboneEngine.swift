import Foundation
import PinyinLattice

public final class PinyinEngine: @unchecked Sendable {
    public let dictionary: DictTrie
    public let learningStore: any LearningStore
    public let inventory: SyllableInventory

    private let english = EnglishLexicon.shared

    public init(dictionary: DictTrie, learningStore: any LearningStore) {
        self.dictionary = dictionary
        self.learningStore = learningStore
        // Start the Latin word list loading now rather than on the first
        // mixed-script keystroke. Otherwise the engine's answer depends on
        // whether a background load happened to finish, which makes behaviour
        // non-deterministic and made an early mixed-language input silently
        // fall back to the raw letters.
        EnglishLexicon.shared.prepare()
        let inventory = dictionary.syllables.isEmpty ? SyllableInventory.standard.syllables : dictionary.syllables
        self.inventory = SyllableInventory(inventory)
    }

    public static func production() throws -> PinyinEngine {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let databaseURL = applicationSupport
            .appendingPathComponent("BiLing", isDirectory: true)
            .appendingPathComponent("learning.sqlite3")
        let store = try EncryptedUserDictionary(url: databaseURL)
        return try PinyinEngine(dictionary: .bundled(), learningStore: store)
    }

    public func candidates(for rawInput: String, context: String = "", generation: UInt64 = 0) -> EngineResult {
        let normalized = PinyinNormalizer.normalize(rawInput)
        let key = PinyinNormalizer.lookupKey(normalized)
        let mode = PinyinNormalizer.mode(for: rawInput, inventory: inventory)
        guard !key.isEmpty else {
            return EngineResult(input: normalized, mode: mode, candidates: [], generation: generation)
        }

        var merged: [String: Candidate] = [:]
        func add(_ candidate: Candidate) {
            if let existing = merged[candidate.text], existing.score >= candidate.score { return }
            merged[candidate.text] = candidate
        }

        let logTotal = dictionary.logTotalWeight
        for var learned in learningStore.candidates(for: key) {
            learned.score = ScoreModel.learnedLogProbability(
                decayedCount: learned.score,
                logMaxWeight: dictionary.logMaxWeight,
                logTotalWeight: logTotal
            )
            add(learned)
        }

        let exactEntries = dictionary.exact(key, limit: 240)
        for entry in exactEntries {
            // One word covering the whole key, spelled out in full: the single
            // most likely story there is. No length bonus is needed — a rival
            // multi-word stitch pays the segment cost for each extra word.
            add(
                Candidate(
                    text: entry.text,
                    pinyin: entry.displayPinyin,
                    source: .system,
                    consumed: key.count,
                    score: ScoreModel.segmentLogProbability(
                        weight: entry.weight,
                        logTotalWeight: logTotal,
                        form: .full
                    )
                )
            )
        }

        for sentence in sentenceCandidates(key: key, limit: 80) { add(sentence) }

        // 简拼: the whole key read as syllable initials (jldx → 吉林大学).
        // When the letters are also full pinyin the interpretation is a long
        // shot, so it sinks; when they are not (jldx, zgrm), it carries the
        // list together with curated Latin entries.
        if key.count <= 8 {
            for entry in dictionary.abbreviated(key, limit: 8) {
                add(
                    Candidate(
                        text: entry.text,
                        pinyin: entry.displayPinyin,
                        source: .abbreviation,
                        consumed: key.count,
                        score: ScoreModel.segmentLogProbability(
                            weight: entry.weight,
                            logTotalWeight: logTotal,
                            form: .initials
                        )
                    )
                )
            }
            for entry in dictionary.mixedCoded(key, limit: 6) {
                add(
                    Candidate(
                        text: entry.text,
                        pinyin: entry.displayPinyin,
                        source: .abbreviation,
                        consumed: key.count,
                        score: ScoreModel.segmentLogProbability(
                            weight: entry.weight,
                            logTotalWeight: logTotal,
                            form: .mixed
                        )
                    )
                )
            }
        }

        // A fully typed curated key always surfaces its canonical form —
        // "claude" → Claude at the top in English mode; "ai" → AI as a lower
        // candidate because 爱 is a real word; "openai" → OpenAI ahead of
        // nonsense syllable stitches like 哦喷爱, because no real word owns
        // that key.
        if let display = english.exactDisplay(for: key) {
            // The letters spell a known term exactly. That is strong evidence
            // unless they also spell valid pinyin, where Chinese keeps priority.
            let score = ScoreModel.latinLogProbability(
                mode == .chinesePrimary ? .curatedExpansion : .spelledOut,
                logTotalWeight: logTotal
            )
            add(
                Candidate(
                    text: display,
                    pinyin: key,
                    source: .english,
                    consumed: key.count,
                    score: score
                )
            )
        }

        if mode == .englishPrimary || mode == .chineseWithEnglish || mode == .literal {
            for (rank, word) in english.completions(for: key, limit: 4).enumerated() {
                add(
                    Candidate(
                        text: word,
                        pinyin: key,
                        source: .english,
                        consumed: key.count,
                        // Later completions are progressively weaker guesses.
                        score: ScoreModel.latinLogProbability(
                            .curatedExpansion,
                            logTotalWeight: logTotal
                        ) + log(1.0 / Double(rank + 1))
                    )
                )
            }
        }

        add(
            Candidate(
                text: rawInput,
                pinyin: key,
                source: .literal,
                consumed: key.count,
                score: mode == .literal
                    ? ScoreModel.literalIntended
                    : ScoreModel.literalLogProbability(length: key.count)
            )
        )

        let sorted = merged.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.source != $1.source {
                let order: [CandidateSource: Int] = [.learned: 0, .sentence: 1, .system: 2, .english: 3, .literal: 4]
                return order[$0.source, default: 9] < order[$1.source, default: 9]
            }
            return $0.text.localizedStandardCompare($1.text) == .orderedAscending
        }
        return EngineResult(input: normalized, mode: mode, candidates: sorted, generation: generation)
    }

    public func recordSelection(input: String, candidate: Candidate, shown: [Candidate], index: Int) {
        learningStore.record(
            pinyin: PinyinNormalizer.lookupKey(input),
            chosen: candidate.text,
            shown: shown.map(\.text),
            chosenIndex: index
        )
    }

    /// Builds every way the buffer can be cut into words, then hands the
    /// lattice to an exact n-best decoder. Candidate *generation* was measured
    /// to be the binding constraint on accuracy, so the search is exact where
    /// it can afford to be rather than a beam that hopes.
    private func sentenceCandidates(key: String, limit: Int) -> [Candidate] {
        let logTotal = dictionary.logTotalWeight
        let characters = Array(key)
        guard characters.count > 1 else { return [] }

        let segmenter = Segmenter(inventory: inventory)
        // Abbreviated readings and Latin words inside the sentence are only
        // considered when the buffer cannot be read as pinyin end to end. This
        // is librime's rule — it deletes abbreviation edges from the syllable
        // graph whenever a complete spelling exists — and it is what keeps
        // ordinary Chinese input byte-for-byte unchanged.
        let keyIsPurePinyin = segmenter.segment(key).isComplete
        var edges: [LatticeEdge] = []

        for position in 0..<characters.count {
            for (end, entry) in dictionary.matches(
                in: characters,
                from: position,
                maxEntriesPerKey: 6
            ) {
                edges.append(
                    LatticeEdge(
                        start: position,
                        end: end,
                        text: entry.text,
                        pinyin: entry.displayPinyin,
                        reading: .lexicon(weight: entry.weight, form: .full)
                    )
                )
            }

            guard !keyIsPurePinyin else { continue }
            let available = characters.count - position

            // A word typed as initials only (dx → 大学), or with its first
            // syllable spelled out and the rest reduced (meiy → 没有).
            if available >= 1 {
                for length in 1...min(available, 9) {
                    let code = String(characters[position..<(position + length)])
                    if length <= 5 {
                        // Length 1 matters: a lone initial standing for one
                        // syllable (d → 第) is how abbreviations actually
                        // decompose when they do not line up with a multi-word
                        // lexicon entry. Without it an abbreviation is only
                        // reachable when it exactly matches a stored code, and
                        // most do not. Single letters fan out widely, so they
                        // get a tighter limit and lean on the transition model
                        // and the abbreviation cost to stay in their place.
                        for entry in dictionary.abbreviated(code, limit: length == 1 ? 120 : 60) {
                            edges.append(
                                LatticeEdge(
                                    start: position,
                                    end: position + length,
                                    text: entry.text,
                                    pinyin: entry.displayPinyin,
                                    reading: .lexicon(weight: entry.weight, form: .initials)
                                )
                            )
                        }
                    }
                    if length >= 3 {
                        for entry in dictionary.mixedCoded(code, limit: 60) {
                            edges.append(
                                LatticeEdge(
                                    start: position,
                                    end: position + length,
                                    text: entry.text,
                                    pinyin: entry.displayPinyin,
                                    reading: .lexicon(weight: entry.weight, form: .mixed)
                                )
                            )
                        }
                    }
                }
            }

            // A Latin word spelled out inside the sentence. Runs that are
            // themselves readable as pinyin belong to Chinese unless they are
            // curated terms: "jing" is an English word but in 北京还有 it is
            // the tail of 北京.
            for candidate in english.embeddedWords(in: characters, from: position) {
                let letters = String(characters[position..<(position + candidate.length)])
                let isCurated = english.curatedCompletion(for: letters) != nil
                    || english.exactDisplay(for: letters) != nil
                guard isCurated || !segmenter.segment(letters).isComplete else { continue }
                edges.append(
                    LatticeEdge(
                        start: position,
                        end: position + candidate.length,
                        text: candidate.display,
                        pinyin: letters,
                        reading: .latin(.spelledOut)
                    )
                )
            }

            // A Latin word the user began and did not finish, closing the
            // buffer (vs → VS Code).
            if position > 0 {
                let suffix = String(characters[position...])
                let completion: (word: String, curated: Bool)?
                if segmenter.segment(suffix).isComplete {
                    completion = english.curatedCompletion(for: suffix).map { ($0, true) }
                } else if let curated = english.curatedCompletion(for: suffix) {
                    completion = (curated, true)
                } else if suffix.count >= 4 {
                    completion = english.bestCompletion(for: suffix).map { ($0, false) }
                } else {
                    completion = nil
                }
                if let completion {
                    edges.append(
                        LatticeEdge(
                            start: position,
                            end: characters.count,
                            text: completion.word,
                            pinyin: suffix,
                            reading: .latin(completion.curated ? .curatedExpansion : .guessedExpansion)
                        )
                    )
                }
            }
        }

        let paths = LatticeDecoder.nBest(
            edges: edges,
            inputLength: characters.count,
            limit: limit,
            logTotalWeight: logTotal,
            transition: { [dictionary] previous, next in
                dictionary.transition(from: previous, to: next)
            }
        )

        // Rescore the finished list with third-order context. Search keeps a
        // bigram state because a trigram state would multiply the lattice;
        // applying the richer model to the ~80 surviving candidates instead
        // costs nothing during search. Only the language-model term is
        // adjusted, so the decoder's written-form costs survive.
        return paths.map { path in
            let adjustment = ScoreModel.trigramAdjustment(
                words: path.words,
                weights: path.weights,
                logTotalWeight: logTotal,
                bigram: { [dictionary] previous, next in
                    dictionary.transition(from: previous, to: next)
                },
                trigram: { [dictionary] first, second, next in
                    dictionary.trigram(first, second, next)
                }
            )
            return Candidate(
                text: spaced(path.text, words: path.pinyin.count),
                pinyin: path.pinyin.joined(separator: " "),
                source: .sentence,
                consumed: key.count,
                score: path.score + adjustment
            )
        }
    }

    /// Chinese and Latin runs get a space between them, matching the
    /// auto-spacing users see on commit.
    private func spaced(_ text: String, words: Int) -> String {
        var output = ""
        for character in text {
            if let previous = output.last {
                let previousLatin = previous.isASCII && previous.isLetter
                let currentLatin = character.isASCII && character.isLetter
                if previousLatin != currentLatin, previous != " ", character != " " {
                    output.append(" ")
                }
            }
            output.append(character)
        }
        return output
    }

    private func appendSegment(_ segment: String, to existing: String) -> String {
        guard let previous = existing.last, let next = segment.first else { return existing + segment }
        let needsSpace = (previous.isASCII && previous.isLetter) != (next.isASCII && next.isLetter)
        return existing + (needsSpace ? " " : "") + segment
    }
}

public enum PrivacyGuard {
    public static func shouldLearn(text: String, source: CandidateSource, bundleIdentifier: String?) -> Bool {
        let blockedBundleFragments = [
            "terminal", "iterm", "warp", "alacritty", "kitty",
            "1password", "bitwarden", "keepass", "keychain",
        ]
        if let bundleIdentifier = bundleIdentifier?.lowercased(),
           blockedBundleFragments.contains(where: bundleIdentifier.contains) {
            return false
        }
        if source == .literal { return false }
        if text.count > 48 { return false }
        if text.contains("@") || text.contains("://") { return false }
        if text.range(of: #"\d{4,}"#, options: .regularExpression) != nil { return false }
        let scalars = text.unicodeScalars
        let asciiRun = scalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.count
        if text.count >= 12 && asciiRun * 4 > text.count * 3 { return false }
        return true
    }
}
