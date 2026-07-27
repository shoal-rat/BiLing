import Testing
@testable import BackboneEngine

private func makeEngine() throws -> PinyinEngine {
    try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
}

@Test func commonWordsAreReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "nihao")
    #expect(result.candidates.contains(where: { $0.text == "你好" }))
}

@Test func heteronymWordIsReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "yinhang")
    #expect(result.candidates.contains(where: { $0.text == "银行" }))
}

@Test func bundledLexiconIsUsefulBeforeLearning() throws {
    let engine = try makeEngine()
    #expect(engine.dictionary.entryCount >= 1_400_000)
    let result = engine.candidates(for: "jilindaxue")
    #expect(result.candidates.first?.text == "吉林大学")
}

@Test func toneMarkedUmlautPinyinIsNormalized() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "lvse")
    #expect(result.candidates.contains(where: { $0.text == "绿色" }))
}

@Test func literalEscapeIsAlwaysReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "vscode")
    #expect(result.candidates.contains(where: { $0.text == "vscode" && $0.source == .literal }))
}

@Test func learningChangesImmediateScore() throws {
    let store = MemoryLearningStore()
    let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
    let before = engine.candidates(for: "xiexie")
    let chosen = try #require(before.candidates.first(where: { $0.text == "谢谢" }))
    engine.recordSelection(input: "xiexie", candidate: chosen, shown: before.candidates, index: 2)
    let after = engine.candidates(for: "xiexie")
    let learned = try #require(after.candidates.first(where: { $0.text == "谢谢" }))
    #expect(learned.source == .learned)
}

@Test func privacyGuardRejectsSensitiveContexts() {
    #expect(!PrivacyGuard.shouldLearn(text: "hello", source: .system, bundleIdentifier: "com.apple.Terminal"))
    #expect(!PrivacyGuard.shouldLearn(text: "12345678", source: .system, bundleIdentifier: "com.apple.TextEdit"))
    #expect(!PrivacyGuard.shouldLearn(text: "raw", source: .literal, bundleIdentifier: nil))
    #expect(PrivacyGuard.shouldLearn(text: "谢谢", source: .system, bundleIdentifier: "com.apple.TextEdit"))
}

@Test func sentenceComposerRanksTheReadmeExampleFirst() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "jilindaxuelajixuexiao")
    #expect(result.candidates.first?.text == "吉林大学垃圾学校")
    #expect(result.candidates.first?.source == .sentence)
}

@Test func englishCuratedCompletionsAnswerInstantly() {
    let lexicon = EnglishLexicon()
    #expect(lexicon.completions(for: "vsc", limit: 3).contains("VS Code"))
    #expect(lexicon.curatedCompletion(for: "gith") == "GitHub")
    #expect(lexicon.completions(for: "x", limit: 3).isEmpty)
}

@Test func curatedDisplayFormsSurface() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "claude").candidates.first?.text == "Claude")
    #expect(engine.candidates(for: "xswl").candidates.first?.text == "xswl")
    #expect(engine.candidates(for: "openai").candidates.first?.text == "OpenAI")
    let ai = engine.candidates(for: "ai").candidates
    #expect(ai.first?.text == "爱")
    #expect(ai.prefix(6).contains(where: { $0.text == "AI" }))
}

@Test func singleLetterBeamComponentsDoNotBeatRealWords() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "fan").candidates.first?.text == "饭")
}

@Test func abbreviationTypingWorks() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "jldx").candidates.first?.text == "吉林大学")
    #expect(engine.candidates(for: "zgrm").candidates.first?.text == "中国人民")
    let mixedTail = engine.candidates(for: "beijinghy").candidates.prefix(3)
    #expect(mixedTail.contains(where: { $0.text == "北京还有" }))
}

@Test func blenderKeepsFrequencyAdvantageWithoutContext() {
    let frequent = Candidate(text: "垃圾", pinyin: "la ji", source: .sentence, consumed: 4, score: 10)
    let slang = Candidate(text: "辣鸡", pinyin: "la ji", source: .sentence, consumed: 4, score: 9.4)
    let scores = ["垃圾": -19.5, "辣鸡": -17.4]
    let cold = CandidateBlender.blend(
        [frequent, slang],
        orderedCandidates: ["辣鸡", "垃圾"],
        scores: scores,
        hasContext: false
    )
    #expect(cold.first?.text == "垃圾")
    let contextual = CandidateBlender.blend(
        [frequent, slang],
        orderedCandidates: ["辣鸡", "垃圾"],
        scores: scores,
        hasContext: true
    )
    #expect(contextual.first?.text == "辣鸡")
}
