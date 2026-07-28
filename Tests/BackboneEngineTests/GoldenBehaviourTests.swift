import Foundation
import Testing

@testable import BackboneEngine

/// Behaviour frozen before the v2 architecture work began.
///
/// These are not aspirational: every expectation here was produced by the
/// engine as it stood at the recorded baseline commit, so a refactor that
/// changes any of them is changing user-visible behaviour and has to say so
/// deliberately. They cover the cases most likely to regress silently while
/// candidate generation is rebuilt underneath.
@Suite("Golden behaviour (pre-v2 baseline)")
struct GoldenBehaviourTests {
    private func engine() throws -> PinyinEngine {
        // Load the Latin word list synchronously so the assertions do not race
        // a background load; the shipping engine starts the same load at init.
        EnglishLexicon.shared.warm()
        return try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
    }

    /// The single most important invariant: ordinary Chinese input must be
    /// byte-for-byte unchanged by anything done to abbreviation or fallback
    /// handling.
    @Test("Everyday words are unchanged")
    func everydayWords() throws {
        let engine = try engine()
        let expectations = [
            ("nihao", "你好"), ("xiexie", "谢谢"), ("zhongguo", "中国"),
            ("shanghai", "上海"), ("pengyou", "朋友"), ("gongzuo", "工作"),
            ("shijian", "时间"), ("wenti", "问题"), ("xuexi", "学习"),
            ("jisuanji", "计算机"), ("shurufa", "输入法"),
        ]
        for (keys, want) in expectations {
            let top = engine.candidates(for: keys).candidates.first?.text
            #expect(top == want, "\(keys) should convert to \(want), got \(top ?? "nil")")
        }
    }

    /// Single syllables resolve by frequency, and a Latin word must never
    /// steal a key that is also valid pinyin.
    @Test("Single syllables and Latin keys keep their owners")
    func singleSyllablesAndLatin() throws {
        let engine = try engine()
        for (keys, want) in [("fan", "饭"), ("ai", "爱"), ("de", "的"), ("shi", "是")] {
            #expect(engine.candidates(for: keys).candidates.first?.text == want)
        }
        // Keys that are not pinyin belong to the Latin term.
        for (keys, want) in [("openai", "OpenAI"), ("github", "GitHub"), ("vscode", "VS Code")] {
            #expect(engine.candidates(for: keys).candidates.first?.text == want)
        }
    }

    /// Sentences the lexicon does not contain, composed by the decoder.
    @Test("Sentences compose from parts")
    func sentenceComposition() throws {
        let engine = try engine()
        let top = engine.candidates(for: "jilindaxuelajixuexiao").candidates.first?.text
        #expect(top == "吉林大学垃圾学校")
    }

    /// Whole-key abbreviation, and the gate that stops abbreviation from
    /// touching input that already parses as pinyin.
    @Test("Abbreviation resolves without disturbing full pinyin")
    func abbreviation() throws {
        let engine = try engine()
        #expect(engine.candidates(for: "jldx").candidates.first?.text == "吉林大学")
        #expect(engine.candidates(for: "zgrm").candidates.first?.text == "中国人民")
        // `fan` parses as pinyin, so no abbreviation reading may outrank 饭.
        #expect(engine.candidates(for: "fan").candidates.first?.text == "饭")
    }

    /// The raw keystrokes must always remain reachable somewhere in the list,
    /// because Return commits them and users rely on that escape hatch.
    @Test("Literal keystrokes are always reachable")
    func literalReachable() throws {
        let engine = try engine()
        for keys in ["asdfgh", "nihao", "jilindaxue", "qqq"] {
            let texts = engine.candidates(for: keys).candidates.map(\.text)
            #expect(texts.contains(keys), "literal \(keys) missing from candidates")
        }
    }

    /// Heteronyms are selected by the reading the user typed, not by a single
    /// stored pronunciation.
    @Test("Heteronyms follow the typed reading")
    func heteronyms() throws {
        let engine = try engine()
        for (keys, want) in [
            ("yinhang", "银行"), ("hangzou", "行走"),
            ("zhongyao", "重要"), ("chongxin", "重新"),
            ("changge", "唱歌"), ("kuaile", "快乐"),
        ] {
            #expect(engine.candidates(for: keys).candidates.first?.text == want)
        }
    }

    /// Mixed-script composition: a Latin word inside a Chinese sentence.
    @Test("Latin words sit inside sentences")
    func mixedScript() throws {
        let engine = try engine()
        let normalise = { (text: String) in text.replacingOccurrences(of: " ", with: "") }
        let economics = engine.candidates(for: "economicslajizhuanye").candidates.first?.text ?? ""
        #expect(normalise(economics) == "economics垃圾专业")
        let vscode = engine.candidates(for: "yongvscodexiedaima").candidates.first?.text ?? ""
        #expect(normalise(vscode) == "用VSCode写代码")
    }

    /// One selection must reorder the very next identical query. This is the
    /// personalisation contract users notice immediately.
    @Test("A single selection sticks")
    func learningSticks() throws {
        let store = MemoryLearningStore()
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
        let keys = "lixi"
        let before = engine.candidates(for: keys).candidates
        guard let alternative = before.first(where: { $0.text != before.first?.text }) else {
            Issue.record("needed at least two candidates for \(keys)")
            return
        }
        engine.recordSelection(
            input: keys,
            candidate: alternative,
            shown: before,
            index: before.firstIndex(where: { $0.text == alternative.text }) ?? 1
        )
        #expect(engine.candidates(for: keys).candidates.first?.text == alternative.text)
    }
}
