import Testing
@testable import PinyinLattice

@Test func preservesAmbiguousSegmentations() {
    let result = Segmenter().segment("xian")
    #expect(result.isComplete)
    #expect(result.paths.contains(["xian"]))
    #expect(result.paths.contains(["xi", "an"]))
}

@Test func apostropheForcesBoundary() {
    let result = Segmenter().segment("xi'an")
    #expect(result.isComplete)
    #expect(result.paths.contains(["xi", "an"]))
}

@Test func ambiguousBoundaryKeepsBothReadings() {
    let result = Segmenter().segment("fangan")
    #expect(result.isComplete)
    #expect(result.paths.contains(["fang", "an"]))
    #expect(result.paths.contains(["fan", "gan"]))
}

@Test func mixedLanguageClassification() {
    #expect(PinyinNormalizer.mode(for: "nihao") == .chinesePrimary)
    #expect(PinyinNormalizer.mode(for: "vscode") == .englishPrimary)
    #expect(PinyinNormalizer.mode(for: "iPhone") == .literal)
}
