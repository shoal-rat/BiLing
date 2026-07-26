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
