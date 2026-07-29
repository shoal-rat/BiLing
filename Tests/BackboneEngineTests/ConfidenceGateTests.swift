import XCTest

@testable import BackboneEngine

/// The calibrated invocation gate and the (dormant) distilled ranker runtime.
final class ConfidenceGateTests: XCTestCase {
    func testBundledGateLoads() throws {
        XCTAssertNotNil(ConfidenceGate.shared, "the calibrated gate ships in the bundle")
    }

    /// Feature computation must match the trainer bit-for-bit — these
    /// probabilities were produced by running the exported JSON through the
    /// Python reference implementation in distill_ranker.py.
    func testProbabilityMatchesPythonReference() throws {
        let gate = try XCTUnwrap(ConfidenceGate.shared)
        let cases: [([Double], Double)] = [
            ([-30.0, -30.5, -31.0, -33.0, -35.0, -36.0], 0.531653385339654),
            ([-22.0, -30.0, -31.0, -34.0], 0.016221049133789252),
            ([-40.0, -40.1, -40.15, -40.2, -40.4, -40.5, -41.0, -42.0, -43.0], 0.8600301849044144),
            ([-12.5], 0.0013790220473436402),
        ]
        for (scores, expected) in cases {
            XCTAssertEqual(
                gate.probabilityWrong(sortedScores: scores), expected, accuracy: 1e-9,
                "diverged from the trainer for \(scores)"
            )
        }
    }

    func testRoutingDirections() throws {
        // A decided list (huge margin) must skip the model; a crowded
        // photo-finish must invoke it.
        XCTAssertFalse(ConfidenceGate.shouldInvokeModel(sortedScores: [-22.0, -30.0, -31.0, -34.0]))
        XCTAssertTrue(
            ConfidenceGate.shouldInvokeModel(
                sortedScores: [-40.0, -40.1, -40.15, -40.2, -40.4, -40.5, -41.0]
            )
        )
        // Single candidate: nothing to rank, never invoke.
        XCTAssertFalse(ConfidenceGate.shouldInvokeModel(sortedScores: [-12.5]))
    }

    func testMalformedGateFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-gate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(#"{"schema":"biling-confidence-gate","version":1,"w":[1,2],"b":0,"mean":[0],"std":[1]}"#.utf8)
            .write(to: url)
        XCTAssertNil(try ConfidenceGate.load(from: url), "wrong shapes must not half-load")

        try Data(#"{"schema":"biling-confidence-gate","version":1,"w":[1,2,3,4],"b":0,"mean":[0,0,0,0],"std":[1,1,0,1]}"#.utf8)
            .write(to: url)
        XCTAssertNil(try ConfidenceGate.load(from: url), "a zero std would divide by zero later")

        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try {
            if try ConfidenceGate.load(from: url) != nil { XCTFail("garbage loaded") }
        }())
    }

    // MARK: - Distilled ranker runtime (dormant until a model earns export)

    private func fixtureRanker() throws -> DistilledRanker {
        // Identity-ish 12→2→1 network with hand-computable arithmetic.
        let featureCount = RankerModel.featureNames.count
        var w1 = [[Double]](repeating: [0.0, 0.0], count: featureCount)
        w1[0] = [1.0, -1.0]   // hidden0 = x0, hidden1 = -x0 (ReLU kills one side)
        let payload: [String: Any] = [
            "schema": "biling-distilled-ranker",
            "version": 1,
            "feature_count": featureCount,
            "hidden": 2,
            "lambda": 0.5,
            "feature_mean": [Double](repeating: 0, count: featureCount),
            "feature_std": [Double](repeating: 1, count: featureCount),
            "w1": w1,
            "b1": [0.0, 0.0],
            "w2": [2.0, 3.0],
            "b2": 0.25,
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("distilled-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(DistilledRanker.load(from: url))
    }

    func testDistilledForwardPass() throws {
        let ranker = try fixtureRanker()
        var features = [Double](repeating: 0, count: RankerModel.featureNames.count)
        features[0] = 2.0
        // hidden = relu([2, -2]) = [2, 0]; out = 2*2 + 0*3 + 0.25 = 4.25
        XCTAssertEqual(ranker.score(features: features), 4.25, accuracy: 1e-12)
        features[0] = -1.5
        // hidden = relu([-1.5, 1.5]) = [0, 1.5]; out = 1.5*3 + 0.25 = 4.75
        XCTAssertEqual(ranker.score(features: features), 4.75, accuracy: 1e-12)
    }

    func testDistilledBlendIsPromotionOnly() throws {
        let ranker = try fixtureRanker()
        let leader = Candidate(text: "甲", pinyin: "jia", source: .system, consumed: 3, score: -10)
        let runnerUp = Candidate(text: "乙", pinyin: "yi", source: .system, consumed: 3, score: -10.4)
        let rescored = ranker.rescored([leader, runnerUp], keyLength: 3)
        // Student prefers the runner-up (less negative score through the
        // network); with the fixture weights its gain is bounded by
        // lambda * (student difference) and the leader is never demoted.
        XCTAssertEqual(rescored.count, 2)
        let newLeaderScore = try XCTUnwrap(rescored.first { $0.text == "甲" }).score
        XCTAssertEqual(newLeaderScore, -10, accuracy: 1e-12, "the incumbent's score must not move")
    }

    func testNoDistilledModelShipsToday() throws {
        // Deliberate: every training run to date is within noise of baseline
        // and the trainer refuses such exports. If this assertion ever fails,
        // a model was added — delete this test and record the holdout numbers
        // in the implementation report instead.
        XCTAssertNil(
            Bundle.module.url(forResource: "distilled-ranker", withExtension: "json"),
            "a distilled model appeared without its paper trail"
        )
    }
}
