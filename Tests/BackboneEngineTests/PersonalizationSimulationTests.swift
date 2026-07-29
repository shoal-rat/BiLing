import Testing
@testable import BackboneEngine

/// Simulates the personalization loop end to end through the public
/// `LearningStore` protocol: a user repeatedly picks a candidate the engine
/// does not rank first, the pick climbs to rank 1, a reset restores stock
/// behaviour, and typing unrelated keys is never affected.
///
/// Uses `MemoryLearningStore`, the same headless store the CLI and the other
/// tests use; `EncryptedUserDictionary` needs the login Keychain, which is not
/// reliably available to `swift test`. The store is exercised only through the
/// protocol, so the scenario is identical for both implementations.
///
/// The target candidate is discovered dynamically — the first system candidate
/// that is *not* the default top — so the test keeps testing the same
/// behaviour when the lexicon's ranking shifts, instead of breaking on a
/// hard-coded word.

private let selectionsToWin = 3

/// A key with a genuine frequency contest, so there is a non-default
/// candidate a user could plausibly keep choosing (会议 vs 回忆 …).
private let contestedKey = "huiyi"
private let unrelatedKey = "nihao"

private func pickTarget(
    in engine: PinyinEngine
) throws -> (defaultTop: String, target: Candidate) {
    let candidates = engine.candidates(for: contestedKey).candidates
    let top = try #require(candidates.first).text
    let target = try #require(
        candidates.first(where: { $0.text != top && $0.source == .system }),
        "need a non-default system candidate to simulate choosing"
    )
    return (top, target)
}

private func choose(_ text: String, for key: String, in engine: PinyinEngine) throws {
    let shown = engine.candidates(for: key).candidates
    let index = try #require(
        shown.firstIndex(where: { $0.text == text }),
        "the chosen candidate must be on screen to be chosen"
    )
    engine.recordSelection(input: key, candidate: shown[index], shown: shown, index: index)
}

@Test func repeatedChoiceReachesRankOne() throws {
    let store = MemoryLearningStore()
    let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
    let (defaultTop, target) = try pickTarget(in: engine)
    #expect(defaultTop != target.text)

    for round in 1...selectionsToWin {
        try choose(target.text, for: contestedKey, in: engine)
        _ = round
    }

    let after = engine.candidates(for: contestedKey).candidates
    #expect(after.first?.text == target.text,
            "after \(selectionsToWin) selections the chosen candidate must lead")
    #expect(after.first?.source == .learned)
}

@Test func resetRestoresStockRanking() throws {
    let store = MemoryLearningStore()
    let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
    let (defaultTop, target) = try pickTarget(in: engine)

    for _ in 1...selectionsToWin {
        try choose(target.text, for: contestedKey, in: engine)
    }
    #expect(engine.candidates(for: contestedKey).candidates.first?.text == target.text)

    store.reset()

    let after = engine.candidates(for: contestedKey).candidates
    #expect(after.first?.text == defaultTop,
            "reset must fall back to the stock default, not keep the learned one")
    #expect(!after.contains(where: { $0.source == .learned }))
}

@Test func unrelatedKeyIsUnaffected() throws {
    let store = MemoryLearningStore()
    let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
    let unrelatedBefore = engine.candidates(for: unrelatedKey).candidates.prefix(5).map(\.text)
    let (_, target) = try pickTarget(in: engine)

    for _ in 1...selectionsToWin {
        try choose(target.text, for: contestedKey, in: engine)
    }

    let unrelatedAfter = engine.candidates(for: unrelatedKey).candidates.prefix(5).map(\.text)
    #expect(unrelatedAfter == unrelatedBefore,
            "learning on \(contestedKey) must not disturb \(unrelatedKey)")
    #expect(!engine.candidates(for: unrelatedKey).candidates
        .contains(where: { $0.source == .learned }))
}
