import Foundation
import Testing
@testable import ZhiyinCore

/// The trie files are build products of Tools/zhuoqin; tests read the ones
/// committed under Resources/Data.
enum Fixtures {
    static let data = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Data")
    static let qinpu: Qinpu = try! Qinpu(path: data.appendingPathComponent("qinpu.trie").path)
    static let vocab: CharTrie = try! CharTrie(path: data.appendingPathComponent("ziqi-vocab.trie").path)
    static var syllables: SyllableTable { qinpu.syllables }

    /// End positions for reading `text` from `keys`, through the real trie
    /// readings — the Swift side of Tools/zhuoqin/pinyin.py's match_text.
    static func ends(_ keys: String, _ text: String) -> [Int] {
        let reader = KeyReader(keys, syllables: syllables)
        let matches = qinpu.trie.walk(reader, from: 0, maxChars: 8)
        return Set(matches.filter { qinpu.trie.text(Int($0.entry)) == text }.map { Int($0.end) }).sorted()
    }
}

@Suite struct ThreeRules {
    @Test func fullSpelling() {
        #expect(Fixtures.ends("jiaoshi", "教室") == [7])
        #expect(Fixtures.ends("zhongguo", "中国") == [8])
    }

    @Test func initialsOnlyWhenNothingIsSpelledOut() {
        // 大 is da/dai: `dan` spells da in full, so 大 cannot be read as an
        // initial there — 大安 is not a reading of dan.
        #expect(Fixtures.ends("dan", "大安").isEmpty)
        #expect(Fixtures.ends("dg", "大哥") == [2])
        #expect(Fixtures.ends("jldx", "吉林大学") == [4])
        #expect(Fixtures.ends("zhg", "中国") == [3])
        #expect(Fixtures.ends("zg", "中国") == [2])
    }

    @Test func prefixOnlyAtTheEnd() {
        #expect(Fixtures.ends("jilindaxu", "吉林大学").contains(9))
        // A prefix in the middle is not a reading.
        #expect(!Fixtures.ends("jilindaxuxiao", "吉林大学").contains(9))
    }

    @Test func apostropheSeparates() {
        #expect(Fixtures.ends("xi'an", "西安") == [5])
        #expect(Fixtures.ends("xian", "西安") == [4])
        #expect(!Fixtures.ends("xi'an", "先").contains(5))
    }

    @Test func umlautSpellings() {
        #expect(Fixtures.ends("lvse", "绿色") == [4])
        #expect(Fixtures.ends("nve", "虐") == [3])
        #expect(Fixtures.ends("nue", "虐") == [3])
    }

    @Test func archaicReadingsAreGone() {
        // pypinyin knows 洋 as xiang; nobody types it that way.
        #expect(Fixtures.ends("xiangqi", "洋气").isEmpty)
        #expect(Fixtures.ends("yangqi", "洋气") == [6])
    }

    @Test func latinIsTypedLetterForLetter() {
        let reader = KeyReader("yongvscode", syllables: Fixtures.vocab.syllables)
        let ends = Fixtures.vocab.latinMatches(reader, from: 4).map(\.1)
        #expect(ends.contains(6))   // "vs"/"VS"
        #expect(ends.contains(10))  // "vscode"-ish pieces up to the end
    }
}

@Suite struct Display {
    @Test func syllabify() {
        let s = Fixtures.syllables
        #expect(Syllabify.display("jilindaxue", syllables: s) == "ji lin da xue")
        #expect(Syllabify.display("jldx", syllables: s) == "j l d x")
        #expect(Syllabify.display("xi'an", syllables: s) == "xi an")
        #expect(Syllabify.display("zhonggu", syllables: s) == "zhong gu")
    }
}

@Suite struct Composing {
    @Test func partialChoiceKeepsComposing() {
        var c = Composition()
        for ch in "jilindaxue" { c.append(ch) }
        #expect(c.choose(Candidate(text: "吉林", consumed: 5, score: 0, voice: .qinpu)) == .continuing)
        #expect(c.keys == "daxue")
        #expect(c.fixedText == "吉林")
        #expect(c.choose(Candidate(text: "大学", consumed: 5, score: 0, voice: .qinpu)) == .commit("吉林大学"))
    }

    @Test func backspaceUnfixes() {
        var c = Composition()
        for ch in "nihao" { c.append(ch) }
        _ = c.choose(Candidate(text: "你", consumed: 2, score: 0, voice: .qinpu))
        #expect(c.keys == "hao")
        c.deleteBackward(); c.deleteBackward(); c.deleteBackward()
        #expect(c.keys.isEmpty)
        c.deleteBackward()
        #expect(c.keys == "ni" && c.fixed.isEmpty)
    }

    @Test func separatorNeverDoubles() {
        var c = Composition()
        c.append("'")
        #expect(c.keys.isEmpty)
        for ch in "xi''an" { c.append(ch) }
        #expect(c.keys == "xi'an")
    }

    @Test func separatorDroppedAfterPartialChoice() {
        var c = Composition()
        for ch in "xi'an" { c.append(ch) }
        _ = c.choose(Candidate(text: "西", consumed: 2, score: 0, voice: .qinpu))
        #expect(c.keys == "an")
    }
}

@Suite struct Score {
    @Test func dictionaryReadsSentences() {
        let q = Fixtures.qinpu
        func top(_ keys: String) -> String? { q.decode(KeyReader(keys, syllables: q.syllables)).first?.text }
        #expect(top("jilindaxue") == "吉林大学")
        #expect(top("nihao") == "你好")
        #expect(top("zhongguorenmin") == "中国人民")
        #expect(top("jilindxmeiykongt") == "吉林大学没有空调")
    }

    @Test func prefixesReadTheStart() {
        let q = Fixtures.qinpu
        let p = q.prefixes(KeyReader("jilindaxue", syllables: q.syllables), limit: 40)
        #expect(p.contains { $0.text == "吉林" && $0.end == 5 })
    }
}

@Suite struct Rapport {
    @Test func remembersAndPromotes() {
        let m = Moqi()
        m.remember(keys: "jiaoshi", text: "教室", overTop: true)
        let q = Fixtures.qinpu
        let reader = KeyReader("jiaoshi", syllables: q.syllables)
        let list = Composer.compose(keys: "jiaoshi", reader: reader, heard: nil, qinpu: q, remembered: m.recall("jiaoshi"))
        #expect(list.first?.text == "教室")
    }

    @Test func neverLearnsAddressesOrNumbers() {
        #expect(!Moqi.learnable(keys: "abc", text: "a@b.com"))
        #expect(!Moqi.learnable(keys: "x", text: "13800138000"))
        #expect(!Moqi.learnable(keys: "vscode", text: "VS Code"))
        #expect(Moqi.learnable(keys: "zhiyin", text: "知音"))
    }
}
