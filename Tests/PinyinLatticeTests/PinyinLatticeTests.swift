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

@Test func incrementalLatticeHandlesBackspace() {
    var lattice = LatticeDAG()
    lattice.append("fangan")
    #expect(lattice.segmentation.isComplete)
    let generation = lattice.generation
    lattice.backspace()
    #expect(lattice.generation == generation + 1)
    #expect(lattice.rawInput == "fanga")
}

@Test func mixedLanguageClassification() {
    #expect(PinyinNormalizer.mode(for: "nihao") == .chinesePrimary)
    #expect(PinyinNormalizer.mode(for: "vscode") == .englishPrimary)
    #expect(PinyinNormalizer.mode(for: "iPhone") == .literal)
}
