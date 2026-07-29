import Foundation
import PinyinLattice
import Testing

@testable import BackboneEngine

/// Guardrails for the modular-source refactor.
///
/// The extraction of whole-key producers out of `PinyinEngine.candidates`
/// was pure code motion, and these tests hold that claim from two sides:
/// the identity test shows the assembled pipeline is deterministic across
/// engine instances, and the per-source tests pin each extracted producer
/// to the behaviour its inlined original had against the bundled lexicon.
@Suite("Whole-key candidate sources", .requiresRealLexicon)
struct CandidateSourceTests {
    private func freshEngine() throws -> PinyinEngine {
        // Load the Latin word list synchronously so assertions do not race a
        // background load; the shipping engine starts the same load at init.
        EnglishLexicon.shared.warm()
        return try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
    }

    /// Mirrors the engine's own inventory construction.
    private func inventory(for dictionary: DictTrie) -> SyllableInventory {
        let syllables = dictionary.syllables.isEmpty
            ? SyllableInventory.standard.syllables : dictionary.syllables
        return SyllableInventory(syllables)
    }

    /// A request built the same way the engine builds one, minus context.
    private func makeRequest(_ raw: String, dictionary: DictTrie) -> CandidateRequest {
        let normalized = PinyinNormalizer.normalize(raw)
        return CandidateRequest(
            rawInput: raw,
            key: PinyinNormalizer.lookupKey(normalized),
            mode: PinyinNormalizer.mode(for: raw, inventory: inventory(for: dictionary)),
            logTotalWeight: dictionary.logTotalWeight,
            contextConditional: { _ in 0 }
        )
    }

    /// Two independently constructed engines must emit candidate-for-candidate,
    /// score-for-score identical lists for the same keystrokes. This is the
    /// contract the modular pipeline has to keep: an ordered array of sources
    /// feeding one merge policy, with nothing timing- or instance-dependent.
    @Test("Two engines produce identical text and score sequences")
    func determinismAcrossEngines() throws {
        let first = try freshEngine()
        let second = try freshEngine()
        let cases: [(key: String, context: String)] = [
            ("jilindaxuelajixuexiao", ""),
            ("jldx", ""),
            ("jilindx", ""),
            ("wangjianlin", ""),
            ("nihao", ""),
            ("fan", ""),
            ("vscode", ""),
            // With committed context: the tail word conditions promotion and
            // the lattice's first transition, and must do so identically.
            ("shurufa", "中文"),
        ]
        for item in cases {
            let a = first.candidates(for: item.key, context: item.context).candidates
            let b = second.candidates(for: item.key, context: item.context).candidates
            #expect(!a.isEmpty, "no candidates for \(item.key)")
            #expect(a.map(\.text) == b.map(\.text), "texts diverged for \(item.key)")
            #expect(a.map(\.score) == b.map(\.score), "scores diverged for \(item.key)")
        }
    }

    @Test("AbbreviationSource expands jldx to 吉林大学")
    func abbreviationSource() throws {
        let dictionary = try DictTrie.bundled()
        let source = AbbreviationSource(dictionary: dictionary)
        let results = source.candidates(for: makeRequest("jldx", dictionary: dictionary))
        #expect(results.contains { $0.text == "吉林大学" && $0.source == .abbreviation })
        // The guard the inlined code carried: whole-key abbreviation stops at
        // eight letters.
        let long = source.candidates(for: makeRequest("jldxjldxj", dictionary: dictionary))
        #expect(long.isEmpty)
    }

    @Test("LexiconWholeKeySource reads the full spelling")
    func lexiconWholeKeySource() throws {
        let dictionary = try DictTrie.bundled()
        let source = LexiconWholeKeySource(dictionary: dictionary)
        let results = source.candidates(for: makeRequest("nihao", dictionary: dictionary))
        #expect(results.contains { $0.text == "你好" && $0.source == .system })
        #expect(results.allSatisfy { $0.consumed == 5 })
    }

    @Test("NameCandidateSource assembles 王建林 for wangjianlin")
    func nameCandidateSource() throws {
        let dictionary = try DictTrie.bundled()
        let source = NameCandidateSource(
            dictionary: dictionary,
            inventory: inventory(for: dictionary)
        )
        let results = source.candidates(for: makeRequest("wangjianlin", dictionary: dictionary))
        #expect(results.contains { $0.text == "王建林" && $0.source == .name })
    }

    @Test("LatinCandidateSource surfaces the curated display form")
    func latinCandidateSource() throws {
        let dictionary = try DictTrie.bundled()
        EnglishLexicon.shared.warm()
        let source = LatinCandidateSource(english: .shared)
        let results = source.candidates(for: makeRequest("vscode", dictionary: dictionary))
        #expect(results.contains { $0.text == "VS Code" && $0.source == .english })
    }

    @Test("LiteralCandidateSource always returns the raw keystrokes")
    func literalCandidateSource() throws {
        let dictionary = try DictTrie.bundled()
        let source = LiteralCandidateSource()
        for raw in ["nihao", "asdfgh", "qqq", "jldx"] {
            let results = source.candidates(for: makeRequest(raw, dictionary: dictionary))
            #expect(results.count == 1)
            #expect(results.first?.text == raw)
            #expect(results.first?.source == .literal)
        }
    }

    @Test("LearnedCandidateSource rescores store counts into log space")
    func learnedCandidateSource() throws {
        let dictionary = try DictTrie.bundled()
        let store = MemoryLearningStore()
        store.record(pinyin: "lixi", chosen: "利息", shown: ["李希", "利息"], chosenIndex: 1)
        let source = LearnedCandidateSource(learningStore: store, dictionary: dictionary)
        let results = source.candidates(for: makeRequest("lixi", dictionary: dictionary))
        #expect(results.count == 1)
        #expect(results.first?.text == "利息")
        #expect(results.first?.source == .learned)
        // The source applies exactly the store-count → log-probability map the
        // inlined loop applied; the raw store count must not leak through.
        let expected = ScoreModel.learnedLogProbability(
            decayedCount: store.candidates(for: "lixi").first?.score ?? 0,
            logMaxWeight: dictionary.logMaxWeight,
            logTotalWeight: dictionary.logTotalWeight
        )
        #expect(results.first?.score == expected)
    }
}
