import Testing
@testable import BackboneEngine

private func makeEngine() throws -> PinyinEngine {
    try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
}

@Test(.requiresRealLexicon) func commonWordsAreReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "nihao")
    #expect(result.candidates.contains(where: { $0.text == "你好" }))
}

@Test(.requiresRealLexicon) func heteronymWordIsReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "yinhang")
    #expect(result.candidates.contains(where: { $0.text == "银行" }))
}

@Test(.requiresRealLexicon) func bundledLexiconIsUsefulBeforeLearning() throws {
    let engine = try makeEngine()
    #expect(engine.dictionary.entryCount >= 1_400_000)
    let result = engine.candidates(for: "jilindaxue")
    #expect(result.candidates.first?.text == "吉林大学")
}

@Test(.requiresRealLexicon) func toneMarkedUmlautPinyinIsNormalized() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "lvse")
    #expect(result.candidates.contains(where: { $0.text == "绿色" }))
}

@Test(.requiresRealLexicon) func literalEscapeIsAlwaysReachable() throws {
    let engine = try makeEngine()
    let result = engine.candidates(for: "vscode")
    #expect(result.candidates.contains(where: { $0.text == "vscode" && $0.source == .literal }))
}

@Test(.requiresRealLexicon) func learningChangesImmediateScore() throws {
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

@Test(.requiresRealLexicon) func sentenceComposerRanksTheReadmeExampleFirst() throws {
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

@Test(.requiresRealLexicon) func curatedDisplayFormsSurface() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "claude").candidates.first?.text == "Claude")
    #expect(engine.candidates(for: "xswl").candidates.first?.text == "xswl")
    #expect(engine.candidates(for: "openai").candidates.first?.text == "OpenAI")
    let ai = engine.candidates(for: "ai").candidates
    #expect(ai.first?.text == "爱")
    #expect(ai.prefix(6).contains(where: { $0.text == "AI" }))
}

@Test(.requiresRealLexicon) func singleLetterBeamComponentsDoNotBeatRealWords() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "fan").candidates.first?.text == "饭")
}

@Test(.requiresRealLexicon) func abbreviationTypingWorks() throws {
    let engine = try makeEngine()
    #expect(engine.candidates(for: "jldx").candidates.first?.text == "吉林大学")
    #expect(engine.candidates(for: "zgrm").candidates.first?.text == "中国人民")
    let mixedTail = engine.candidates(for: "beijinghy").candidates.prefix(3)
    #expect(mixedTail.contains(where: { $0.text == "北京还有" }))
}

@Test func theModelIsOnlyTrustedWhereItHasEvidence() {
    // No conditional structure to judge — a one-character candidate with
    // nothing before it — means no vote at all, so the lexicon order stands.
    #expect(ScoreModel.languageModelWeight(hasContext: false, candidateLength: 1) == 0)
    // Evidence accumulates with context and with candidate length, and the
    // weight rises monotonically without ever reaching its swept ceiling
    // (the ceiling itself is calibration, re-swept when score semantics
    // change — the property here is the shape, not the constant).
    let cold = ScoreModel.languageModelWeight(hasContext: false, candidateLength: 4)
    let warm = ScoreModel.languageModelWeight(hasContext: true, candidateLength: 4)
    let longer = ScoreModel.languageModelWeight(hasContext: true, candidateLength: 9)
    #expect(
        cold > 0 && cold < warm && warm < longer
            && longer < ScoreModel.languageModelScale(hasContext: true)
    )
}

@Test func theModelMayPromoteButNeverArbitrarilyDemote() {
    // The lexicon's own first choice is the reference point, so a candidate the
    // model likes less than that choice cannot be pushed further down.
    let preferred = Candidate(text: "利息", pinyin: "li xi", source: .system, consumed: 4, score: -9.0)
    let other = Candidate(text: "力系", pinyin: "li xi", source: .system, consumed: 4, score: -11.0)
    let modelDislikesBoth = ["利息": -30.0, "力系": -40.0]
    let blended = CandidateBlender.blend(
        [preferred, other],
        orderedCandidates: ["利息", "力系"],
        scores: modelDislikesBoth,
        hasContext: true
    )
    #expect(blended.first?.text == "利息")
    #expect(blended.first?.score == preferred.score)
}
