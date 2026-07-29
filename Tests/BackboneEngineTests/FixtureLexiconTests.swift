import Foundation
import Testing

@testable import BackboneEngine

/// Structural tests that run against the checked-in fixture lexicon
/// (Tests/Fixtures/fixture-lexicon.sqlite3, built by
/// scripts/build_fixture_lexicon.py). These are the tests CI relies on when
/// the real lexicon is only an LFS pointer: they prove the engine can open a
/// production-schema database, serve exact, abbreviated and mixed-code
/// lookups, load the transition and name models, behave deterministically,
/// and reject files that merely claim to be lexicons.
@Suite("Fixture lexicon")
struct FixtureLexiconTests {
    private func fixtureDictionary() throws -> DictTrie {
        try DictTrie(contentsOf: TestLexicon.fixtureURL)
    }

    private func fixtureEngine() throws -> PinyinEngine {
        EnglishLexicon.shared.warm()
        return try PinyinEngine(
            dictionary: fixtureDictionary(),
            learningStore: MemoryLearningStore()
        )
    }

    @Test("The fixture opens with every production-side table populated")
    func fixtureLoads() throws {
        let dictionary = try fixtureDictionary()
        #expect(dictionary.entryCount > 150)
        // Metadata was read, not defaulted: the fixture's normalisers are its
        // own sums, nowhere near the hard-coded fallbacks (22.0 / 16.0).
        #expect(abs(dictionary.logTotalWeight - 22.0) > 0.5)
        #expect(dictionary.logTotalWeight > 15 && dictionary.logTotalWeight < 25)
        #expect(dictionary.logMaxWeight > 10 && dictionary.logMaxWeight < 20)
        #expect(dictionary.transitionCount > 0)
        #expect(dictionary.hasNameModel)
        #expect(dictionary.trigram("吉林大学", "垃圾", "学校") > 0)
        #expect(dictionary.surnameLogProbability("王") != nil)
        #expect(dictionary.givenNameLogProbability("建", position: 1) != nil)
    }

    @Test("Exact, abbreviated and mixed-code lookups answer from the fixture")
    func basicCandidates() throws {
        let dictionary = try fixtureDictionary()
        #expect(dictionary.exact("nihao").contains { $0.text == "你好" })
        #expect(dictionary.abbreviated("jldx").contains { $0.text == "吉林大学" })
        // Mixed codes go through the partial index whose predicate the query
        // must repeat (`mixed <> ''`); a schema drift here breaks this first.
        #expect(dictionary.mixedCoded("jildx").contains { $0.text == "吉林大学" })

        let engine = try fixtureEngine()
        #expect(engine.candidates(for: "nihao").candidates.contains { $0.text == "你好" })
        #expect(engine.candidates(for: "jldx").candidates.contains { $0.text == "吉林大学" })
    }

    @Test("Two engines over the same fixture produce identical output")
    func determinism() throws {
        let first = try fixtureEngine()
        let second = try fixtureEngine()
        for keys in ["nihao", "jldx", "zhongguo", "jilindaxue", "women", "lvse", "jintiantianqi"] {
            let a = first.candidates(for: keys).candidates.map { "\($0.text)|\($0.score)" }
            let b = second.candidates(for: keys).candidates.map { "\($0.text)|\($0.score)" }
            #expect(a == b, "\(keys) diverged between two identically built engines")
        }
    }

    @Test(
        "bundled() honours BILING_LEXICON_PATH",
        .enabled(
            if: ProcessInfo.processInfo.environment[DictTrie.lexiconPathVariable] != nil,
            "Only meaningful when the override is set (CI sets it to the fixture)."
        )
    )
    func environmentOverride() throws {
        let override = try #require(
            ProcessInfo.processInfo.environment[DictTrie.lexiconPathVariable]
        )
        #expect(DictTrie.resolvedLexiconURL()?.path == URL(fileURLWithPath: override).path)
        let viaEnvironment = try DictTrie.bundled()
        let direct = try DictTrie(contentsOf: URL(fileURLWithPath: override))
        #expect(viaEnvironment.entryCount == direct.entryCount)
        #expect(viaEnvironment.entryCount > 0)
    }

    @Test("A truncated database is rejected at init with a diagnosis")
    func truncatedCopyIsRejected() throws {
        let data = try Data(contentsOf: TestLexicon.fixtureURL)
        let truncated = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-truncated-\(UUID().uuidString).sqlite3")
        try data.prefix(512).write(to: truncated)
        defer { try? FileManager.default.removeItem(at: truncated) }
        #expect(throws: BackboneError.self) {
            _ = try DictTrie(contentsOf: truncated)
        }
    }

    @Test("A Git LFS pointer file is rejected at init, not opened as SQLite")
    func pointerFileIsRejected() throws {
        let pointer = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-pointer-\(UUID().uuidString).sqlite3")
        let body = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:525c22b973ab9e46330a3f281a921a3e5375a1a2be6b95bfa60d3a2276b0d4a5
        size 233451520

        """
        try body.write(to: pointer, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pointer) }
        #expect(throws: BackboneError.self) {
            _ = try DictTrie(contentsOf: pointer)
        }
    }
}
