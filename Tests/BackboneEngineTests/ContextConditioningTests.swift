import XCTest

@testable import BackboneEngine

/// Engine-level context: the committed tail word conditions the deterministic
/// ranking, with no model involved.
final class ContextConditioningTests: XCTestCase {
    private static let engine = try! PinyinEngine(
        dictionary: .bundled(), learningStore: MemoryLearningStore()
    )

    private func top(_ key: String, context: String = "") -> String {
        Self.engine.candidates(for: key, context: context).candidates.first?.text ?? ""
    }

    func testCommittedWordFlipsHomophone() {
        // 走进 (walk into) selects the place; 我们的 (our) keeps the person.
        XCTAssertEqual(top("jiaoshi"), "教师")
        XCTAssertEqual(top("jiaoshi", context: "走进"), "教室")
        XCTAssertEqual(top("jiaoshi", context: "我们的"), "教师")
    }

    func testEmptyAndNonHanContextChangeNothing() {
        let cold = Self.engine.candidates(for: "jiaoshi").candidates
        for context in ["", "hello", "123, "] {
            let conditioned = Self.engine.candidates(for: "jiaoshi", context: context).candidates
            XCTAssertEqual(cold.map(\.text), conditioned.map(\.text), "context \(context)")
            for (lhs, rhs) in zip(cold, conditioned) {
                XCTAssertEqual(lhs.score, rhs.score, accuracy: 1e-12)
            }
        }
    }

    func testPromotionNeverDemotesWholeKeyCandidates() {
        // The context delta is promotion-only where it is applied as a
        // formula: whole-key lexicon and abbreviation candidates. Sentence
        // candidates carry a weaker guarantee — each *path* only gains, but
        // under the finite state cap a promoted rival can evict the path a
        // tail candidate previously scored through, so list-level
        // monotonicity holds only for the direct sources.
        for context in ["氨苄", "走进", "船停在"] {
            let cold = Dictionary(
                Self.engine.candidates(for: "anbian").candidates
                    .filter { $0.source == .system || $0.source == .abbreviation }
                    .map { ($0.text, $0.score) },
                uniquingKeysWith: { first, _ in first }
            )
            let conditioned = Self.engine.candidates(for: "anbian", context: context).candidates
            var shared = 0
            for candidate in conditioned
            where candidate.source == .system || candidate.source == .abbreviation {
                guard let coldScore = cold[candidate.text] else { continue }
                shared += 1
                XCTAssertGreaterThanOrEqual(
                    candidate.score, coldScore - 1e-9,
                    "\(candidate.text) demoted under context \(context)"
                )
            }
            XCTAssertGreaterThan(shared, 0, "comparison must cover at least the lexicon words")
        }
    }
}
