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

        for sentence in sentenceCandidates(key: key, limit: 24) { add(sentence) }

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

    private struct Beam {
        var position: Int
        var text: String
        var pinyin: [String]
        var score: Double
        var componentCount: Int
        /// The word this path ended on, so the next extension can be scored
        /// conditionally rather than in isolation.
        var previousWord: String = DictTrie.sentenceStart
    }

    private func sentenceCandidates(key: String, limit: Int) -> [Candidate] {
        let logTotal = dictionary.logTotalWeight
        let characters = Array(key)
        guard characters.count > 1 else { return [] }
        var beams = [Beam(position: 0, text: "", pinyin: [], score: 0, componentCount: 0)]
        func transitionScore(
            _ beam: Beam,
            _ entry: LexiconEntry,
            _ form: ScoreModel.TypingForm
        ) -> Double {
            beam.score + ScoreModel.transitionLogProbability(
                weight: entry.weight,
                logTotalWeight: logTotal,
                conditional: dictionary.transition(from: beam.previousWord, to: entry.text),
                form: form
            )
        }
        var completed: [Beam] = []
        // Matches depend only on the start position, never on the beam that asks;
        // memoizing them caps lexicon lookups at one batch per input position.
        var matchesByPosition: [Int: [(Int, LexiconEntry)]] = [:]
        func matches(from position: Int) -> [(Int, LexiconEntry)] {
            if let cached = matchesByPosition[position] { return cached }
            // Six homophones per key rather than three. An oracle pass over
            // the lexicon showed the correct word is present 98.5% of the time
            // but the search was only allowed to look at three, so fan-in — not
            // the lexicon — set the coverage ceiling. Six is where the measured
            // curve flattens: +0.7 coverage for +0.7 ms, while ten and twelve
            // buy almost nothing more.
            let fresh = dictionary.matches(in: characters, from: position, maxEntriesPerKey: 6)
            matchesByPosition[position] = fresh
            return fresh
        }
        // A tail that still parses as pinyin may only complete to curated
        // English (vscode, github, …); otherwise rare system words would leak
        // into ordinary Chinese sentences. Non-pinyin tails get the full list.
        let segmenter = Segmenter(inventory: inventory)
        var englishTailByPosition: [Int: (word: String, curated: Bool)?] = [:]
        func englishTail(from position: Int) -> (word: String, curated: Bool)? {
            if let cached = englishTailByPosition[position] { return cached }
            let suffix = String(characters[position...])
            let completion: (word: String, curated: Bool)?
            if segmenter.segment(suffix).isComplete {
                // Still valid pinyin, so only a curated word may claim it.
                completion = english.curatedCompletion(for: suffix).map { ($0, true) }
            } else if let curated = english.curatedCompletion(for: suffix) {
                completion = (curated, true)
            } else if suffix.count >= 4 {
                // Below four letters the system word list completes noise —
                // "is" → "ism", "ei" → "eight" — and outbids real Chinese
                // readings of the same tail.
                completion = english.bestCompletion(for: suffix).map { ($0, false) }
            } else {
                completion = nil
            }
            englishTailByPosition[position] = completion
            return completion
        }
        // Abbreviated segments anywhere in the sentence, which is how people
        // actually type fast: jilin·dx·meiy·kongt = 吉林·大学·没有·空调.
        // A word may appear as initials only (dx → 大学) or first-syllable-full
        // then initials (meiy → 没有). Both are gated on the key not parsing as
        // pinyin, so ordinary input can never be broken up this way.
        var codedByPosition: [Int: [(Int, LexiconEntry, Bool)]] = [:]
        func codedSegments(from position: Int) -> [(Int, LexiconEntry, Bool)] {
            guard !keyIsPurePinyin else { return [] }
            if let cached = codedByPosition[position] { return cached }
            var fresh: [(Int, LexiconEntry, Bool)] = []
            let available = characters.count - position
            guard available >= 2 else {
                codedByPosition[position] = []
                return []
            }
            // Initials-only codes are short by construction; mixed codes carry
            // one spelled-out syllable, so they run longer.
            for length in 2...min(available, 9) {
                let code = String(characters[position..<(position + length)])
                if length <= 5 {
                    for entry in dictionary.abbreviated(code, limit: 2) {
                        fresh.append((position + length, entry, true))
                    }
                }
                if length >= 3 {
                    for entry in dictionary.mixedCoded(code, limit: 2) {
                        fresh.append((position + length, entry, false))
                    }
                }
            }
            codedByPosition[position] = fresh
            return fresh
        }

        // 混合简拼 tail: full pinyin followed by initials (beijinghy →
        // 北京 + 还有). Only when the whole key does NOT parse as pinyin —
        // otherwise fully valid inputs like "fan" would sprout 发+你.
        let keyIsPurePinyin = segmenter.segment(key).isComplete
        let allowAbbreviationTails = !keyIsPurePinyin

        // An English word sitting inside the sentence (economicslajizhuanye →
        // economics + 垃圾专业; wozaipolytechnicxuedeleisi → 我在 + polytechnic
        // + 学的累死). Gated on the key not parsing as pinyin, so ordinary
        // Chinese input can never be broken up by an accidental English match
        // — "shanghai" and "wanting" are both English words and valid pinyin.
        var embeddedByPosition: [Int: [(display: String, length: Int)]] = [:]
        func embeddedEnglish(from position: Int) -> [(display: String, length: Int)] {
            guard !keyIsPurePinyin else { return [] }
            if let cached = embeddedByPosition[position] { return cached }
            // A run that is itself readable as pinyin belongs to Chinese
            // unless it is a curated term: "jing" is in the English word list
            // but in 北京还有 it is the tail of 北京, not a word of its own.
            let fresh = english.embeddedWords(in: characters, from: position)
                .filter { candidate in
                    let letters = String(
                        characters[position..<(position + candidate.length)]
                    )
                    if english.curatedCompletion(for: letters) != nil { return true }
                    if english.exactDisplay(for: letters) != nil { return true }
                    return !segmenter.segment(letters).isComplete
                }
            embeddedByPosition[position] = fresh
            return fresh
        }
        var abbrevTailByPosition: [Int: [LexiconEntry]] = [:]
        func abbrevTail(from position: Int) -> [LexiconEntry] {
            if let cached = abbrevTailByPosition[position] { return cached }
            let remaining = characters.count - position
            let fresh: [LexiconEntry]
            if allowAbbreviationTails, position > 0, remaining >= 1, remaining <= 6 {
                fresh = dictionary.abbreviated(String(characters[position...]), limit: 2)
            } else {
                fresh = []
            }
            abbrevTailByPosition[position] = fresh
            return fresh
        }

        while !beams.isEmpty {
            var next: [Beam] = []
            for beam in beams {
                if beam.position == characters.count {
                    completed.append(beam)
                    continue
                }
                for (end, entry) in matches(from: beam.position) {
                    next.append(
                        Beam(
                            position: end,
                            text: appendSegment(entry.text, to: beam.text),
                            pinyin: beam.pinyin + [entry.displayPinyin],
                            score: transitionScore(beam, entry, .full),
                            componentCount: beam.componentCount + 1,
                            previousWord: entry.text
                        )
                    )
                }
                for (end, entry, initialsOnly) in codedSegments(from: beam.position) {
                    next.append(
                        Beam(
                            position: end,
                            text: appendSegment(entry.text, to: beam.text),
                            pinyin: beam.pinyin + [entry.displayPinyin],
                            score: transitionScore(beam, entry, initialsOnly ? .initials : .mixed),
                            componentCount: beam.componentCount + 1,
                            previousWord: entry.text
                        )
                    )
                }
                for candidate in embeddedEnglish(from: beam.position) {
                    let consumed = candidate.length
                    next.append(
                        Beam(
                            position: beam.position + consumed,
                            text: appendSegment(candidate.display, to: beam.text),
                            pinyin: beam.pinyin
                                + [String(characters[beam.position..<(beam.position + consumed)])],
                            score: beam.score + ScoreModel.latinLogProbability(
                                .spelledOut,
                                logTotalWeight: logTotal
                            ),
                            componentCount: beam.componentCount + 1,
                            previousWord: candidate.display
                        )
                    )
                }
                if let completion = englishTail(from: beam.position) {
                    next.append(
                        Beam(
                            position: characters.count,
                            text: appendSegment(completion.word, to: beam.text),
                            pinyin: beam.pinyin + [String(characters[beam.position...])],
                            // A curated term is a confident expansion; a guess
                            // from the system word list is not, and must not
                            // outbid a real Chinese reading of the same tail.
                            score: beam.score + ScoreModel.latinLogProbability(
                                completion.curated ? .curatedExpansion : .guessedExpansion,
                                logTotalWeight: logTotal
                            ),
                            componentCount: beam.componentCount + 1,
                            previousWord: completion.word
                        )
                    )
                }
                for entry in abbrevTail(from: beam.position) {
                    let tailLength = characters.count - beam.position
                    next.append(
                        Beam(
                            position: characters.count,
                            text: appendSegment(entry.text, to: beam.text),
                            pinyin: beam.pinyin + [entry.displayPinyin],
                            score: transitionScore(beam, entry, .initials),
                            componentCount: beam.componentCount + 1,
                            previousWord: entry.text
                        )
                    )
                }
            }
            // Prune per end position, never globally. Scores are sums of
            // log-probabilities, so a path that has consumed less of the input
            // always outscores one that has consumed more; a single global
            // cutoff therefore throws away well-advanced paths and keeps
            // whichever prefix happens to be shortest. Comparing only paths
            // that have reached the same position is the standard lattice
            // formulation and is what keeps genuine alternatives — 大学 beside
            // 东西 — alive to be re-ranked later.
            var byPosition: [Int: [Beam]] = [:]
            for beam in next {
                byPosition[beam.position, default: []].append(beam)
            }
            beams = byPosition.values.flatMap {
                $0.sorted { $0.score > $1.score }.prefix(12)
            }
        }

        var seen: Set<String> = []
        return completed
            .filter { $0.componentCount > 1 && seen.insert($0.text).inserted }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map {
                Candidate(
                    text: $0.text,
                    pinyin: $0.pinyin.joined(separator: " "),
                    source: .sentence,
                    consumed: key.count,
                    score: $0.score
                )
            }
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
