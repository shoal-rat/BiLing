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

        for learned in learningStore.candidates(for: key) { add(learned) }

        let exactEntries = dictionary.exact(key, limit: 240)
        for entry in exactEntries {
            let wordLengthBonus = log1p(Double(entry.text.count)) * 1.8
            let syllableCount = entry.displayPinyin.split(separator: " ").count
            let exactPhraseBonus = entry.text.count > 1
                ? 7 + min(9, Double(syllableCount) * 1.5)
                : 0
            add(
                Candidate(
                    text: entry.text,
                    pinyin: entry.displayPinyin,
                    source: .system,
                    consumed: key.count,
                    score: log1p(max(0, entry.weight)) + wordLengthBonus + exactPhraseBonus
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
                        score: log1p(max(0, entry.weight)) + (mode == .chinesePrimary ? -2 : 10)
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
            let score: Double
            if mode != .chinesePrimary {
                score = 26
            } else if exactEntries.isEmpty {
                score = 17
            } else {
                score = 9
            }
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
                        score: (mode == .englishPrimary ? 22 : 7) - Double(rank)
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
                score: mode == .literal ? 100 : (mode == .englishPrimary ? 18 : -20)
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
    }

    private func sentenceCandidates(key: String, limit: Int) -> [Candidate] {
        let characters = Array(key)
        guard characters.count > 1 else { return [] }
        var beams = [Beam(position: 0, text: "", pinyin: [], score: 0, componentCount: 0)]
        var completed: [Beam] = []
        // Matches depend only on the start position, never on the beam that asks;
        // memoizing them caps lexicon lookups at one batch per input position.
        var matchesByPosition: [Int: [(Int, LexiconEntry)]] = [:]
        func matches(from position: Int) -> [(Int, LexiconEntry)] {
            if let cached = matchesByPosition[position] { return cached }
            let fresh = dictionary.matches(in: characters, from: position, maxEntriesPerKey: 3)
            matchesByPosition[position] = fresh
            return fresh
        }
        // A tail that still parses as pinyin may only complete to curated
        // English (vscode, github, …); otherwise rare system words would leak
        // into ordinary Chinese sentences. Non-pinyin tails get the full list.
        let segmenter = Segmenter(inventory: inventory)
        var englishTailByPosition: [Int: String?] = [:]
        func englishTail(from position: Int) -> String? {
            if let cached = englishTailByPosition[position] { return cached }
            let suffix = String(characters[position...])
            let completion = segmenter.segment(suffix).isComplete
                ? english.curatedCompletion(for: suffix)
                : english.bestCompletion(for: suffix)
            englishTailByPosition[position] = completion
            return completion
        }
        // 混合简拼 tail: full pinyin followed by initials (beijinghy →
        // 北京 + 还有). Only when the whole key does NOT parse as pinyin —
        // otherwise fully valid inputs like "fan" would sprout 发+你.
        let allowAbbreviationTails = !segmenter.segment(key).isComplete
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
                    // Single-letter keys (嗯 n, 呣 m…) stitch valid-looking
                    // nonsense like 发嗯 for "fan"; tax them so real words win.
                    let shortKeyPenalty: Double = end - beam.position == 1 ? 8 : 0
                    next.append(
                        Beam(
                            position: end,
                            text: appendSegment(entry.text, to: beam.text),
                            pinyin: beam.pinyin + [entry.displayPinyin],
                            score: beam.score + log1p(max(0, entry.weight))
                                + Double(end - beam.position) * 0.35 - shortKeyPenalty,
                            componentCount: beam.componentCount + 1
                        )
                    )
                }
                if let completion = englishTail(from: beam.position) {
                    next.append(
                        Beam(
                            position: characters.count,
                            text: appendSegment(completion, to: beam.text),
                            pinyin: beam.pinyin + [String(characters[beam.position...])],
                            score: beam.score + 10,
                            componentCount: beam.componentCount + 1
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
                            score: beam.score + log1p(max(0, entry.weight))
                                - (tailLength == 1 ? 8 : 2),
                            componentCount: beam.componentCount + 1
                        )
                    )
                }
            }
            beams = Array(
                next.sorted {
                    let lhs = $0.score / Double(max(1, $0.componentCount))
                    let rhs = $1.score / Double(max(1, $1.componentCount))
                    return lhs > rhs
                }.prefix(64)
            )
        }

        var seen: Set<String> = []
        return completed
            .filter { $0.componentCount > 1 && seen.insert($0.text).inserted }
            .sorted { $0.score / Double($0.componentCount) > $1.score / Double($1.componentCount) }
            .prefix(limit)
            .map {
                Candidate(
                    text: $0.text,
                    pinyin: $0.pinyin.joined(separator: " "),
                    source: .sentence,
                    consumed: key.count,
                    score: $0.score / Double($0.componentCount) + 2
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
