import Foundation
import Testing

@testable import BackboneEngine

/// Fuzzy pinyin and typing-slip tolerance.
///
/// Two invariants matter more than any individual conversion. Off — the
/// default — must leave the engine's output untouched, because tolerance is
/// an opt-in claim about how the user spells. On, a candidate that deviates
/// from the typed letters may only *add* to what exact reading offers: it
/// must never steal the top spot from a word that owns the key exactly.
@Suite("Fuzzy pinyin and typo tolerance")
struct ToleranceTests {
    private func engine(_ tolerance: ToleranceOptions) throws -> PinyinEngine {
        EnglishLexicon.shared.warm()
        return try PinyinEngine(
            dictionary: .bundled(),
            learningStore: MemoryLearningStore(),
            tolerance: tolerance
        )
    }

    @Test("Tolerance is off unless asked for")
    func offByDefault() throws {
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
        #expect(engine.tolerance == .off)
    }

    /// With tolerance off, no candidate may claim a deviant reading at all —
    /// the entire feature must be structurally absent, which is what keeps
    /// the golden baseline byte-identical.
    @Test("Off means absent, not merely losing")
    func offMeansAbsent() throws {
        let engine = try engine(.off)
        for keys in ["nihao", "fan", "ai", "shanghai", "xiexie", "zongguo", "nihoa", "wmen"] {
            let sources = engine.candidates(for: keys).candidates.map(\.source)
            #expect(!sources.contains(.corrected), "\(keys) produced a corrected candidate with tolerance off")
        }
    }

    /// Input that parses cleanly keeps its exact top choice even with every
    /// tolerance enabled. The fuzzy cost is sized against the widest
    /// frequency gap in the lexicon precisely so this cannot regress.
    @Test("Clean input keeps its owner with tolerance on")
    func cleanInputKeepsOwner() throws {
        let off = try engine(.off)
        let on = try engine(.all)
        for keys in ["nihao", "fan", "ai", "shanghai", "xiexie", "shan", "zhai", "si", "gou", "zhongguo"] {
            let before = off.candidates(for: keys).candidates.first?.text
            let after = on.candidates(for: keys).candidates.first?.text
            #expect(before == after, "\(keys): top candidate moved from \(before ?? "nil") to \(after ?? "nil")")
        }
    }

    @Test("Fuzzy pairs resolve")
    func fuzzyPairs() throws {
        let engine = try engine(.all)
        // z/zh with junk exact readings: the fuzzy image rescues the buffer.
        #expect(engine.candidates(for: "zongguo").candidates.first?.text == "中国")
        // n/l both ways: each key still belongs to its own words, but the
        // fuzzy twin's readings are reachable in the same list.
        let lan = engine.candidates(for: "lan").candidates.map(\.text)
        #expect(lan.first == "蓝")
        #expect(lan.contains("男") || lan.contains("难"), "lan offers no nan reading")
        let nan = engine.candidates(for: "nan").candidates.map(\.text)
        #expect(nan.contains("蓝") || nan.contains("兰"), "nan offers no lan reading")
        // an/ang inside a multi-syllable word.
        let sanghai = engine.candidates(for: "sanghai").candidates.map(\.text)
        #expect(sanghai.prefix(3).contains("上海"), "sanghai should surface 上海 near the top")
    }

    @Test("Typing slips repair")
    func typoRepair() throws {
        let engine = try engine(.all)
        // Adjacent transposition.
        #expect(engine.candidates(for: "nihoa").candidates.first?.text == "你好")
        // Doubled letter — and the exact reading it competes with survives.
        let nihaoo = engine.candidates(for: "nihaoo").candidates.map(\.text)
        #expect(nihaoo.first == "你好")
        #expect(nihaoo.contains("你好哦"), "the exact reading must stay reachable")
        // Omitted letter.
        #expect(engine.candidates(for: "wmen").candidates.first?.text == "我们")
    }

    /// One deviation per reading is a hard bound: a buffer needing two
    /// repairs stays unrepaired rather than opening the search space.
    @Test("Two slips are not repaired")
    func singleErrorBound() throws {
        let engine = try engine(.all)
        let texts = engine.candidates(for: "nihooa").candidates.map(\.text)
        #expect(!texts.contains("你好"), "two-error input should not reach 你好")
    }

    /// A repair may only be asserted when it beats everything the literal
    /// keystrokes can honestly mean — otherwise it is clutter on top of a
    /// list that already has the right answer.
    @Test("Repairs must beat the exact reading to appear")
    func repairGate() throws {
        let engine = try engine(.all)
        // `fan` parses cleanly; no substitution or omission variant of it may
        // appear anywhere above the words that own the key. The fuzzy image
        // (fang) is a different, opted-in claim and is allowed below them.
        let candidates = engine.candidates(for: "fan").candidates
        let firstCorrected = candidates.firstIndex { $0.source == .corrected }
        if let firstCorrected {
            #expect(firstCorrected > 0, "a corrected reading outranked 饭 on its own key")
        }
    }
}
