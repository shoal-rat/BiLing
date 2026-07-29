import Foundation
import IPCProtocol
import XCTest

@testable import LLMRanker

/// Tests for the llama.cpp Qwen bridge.
///
/// Tests that need real inference locate the GGUF the way the app does
/// (BILING_MODEL_PATH first, then the repository's Models/ directory, then
/// ModelLocator.bundledModelURL()) and skip cleanly when it is absent, so
/// the suite passes on machines without the 400 MB model file. Load-failure
/// and configuration tests run everywhere.
final class LLMRankerTests: XCTestCase {
    // MARK: - Model discovery

    static func locateModel() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["BILING_MODEL_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        let repoModel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LLMRankerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Models/\(ModelLocator.fileName)")
        candidates.append(repoModel)
        candidates.append(ModelLocator.bundledModelURL())
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One shared warm instance for the scoring tests; loading the model per
    /// test would multiply the suite's wall time for no coverage.
    nonisolated(unsafe) static var sharedRanker: QwenRanker?

    /// ggml-metal asserts at process exit if a llama context still holds
    /// Metal residency sets when its static destructors run, so the shared
    /// instance must be torn down with the suite, not left to exit().
    override class func tearDown() {
        sharedRanker = nil
        super.tearDown()
    }

    private func requireModelURL() throws -> URL {
        guard let url = Self.locateModel() else {
            throw XCTSkip(
                "Qwen GGUF not found (checked BILING_MODEL_PATH, Models/, and the app's bundled path); skipping model-dependent test."
            )
        }
        return url
    }

    private func requireSharedRanker() throws -> QwenRanker {
        let url = try requireModelURL()
        if Self.sharedRanker == nil {
            Self.sharedRanker = try QwenRanker(modelURL: url)
        }
        return Self.sharedRanker!
    }

    private func makeRequest(
        clientID: UUID = UUID(),
        generation: UInt64 = 1,
        context: String,
        candidates: [String]
    ) -> RankRequest {
        RankRequest(
            clientID: clientID,
            generation: generation,
            input: "test",
            committedContext: context,
            candidates: candidates
        )
    }

    private func scores(
        _ ranker: QwenRanker,
        context: String,
        candidates: [String]
    ) async throws -> [String: Double] {
        let reply = try await ranker.rank(
            makeRequest(context: context, candidates: candidates)
        )
        let unwrapped = try XCTUnwrap(reply, "scoring unexpectedly timed out")
        return unwrapped.scores
    }

    /// A long Chinese context that decodes for long enough (cold) that a
    /// cancel or a 1 ms deadline reliably lands mid-flight.
    private static let longContext = String(
        repeating: "今天的天气非常好，我们一起去公园散步，路上遇到了很多熟悉的朋友。",
        count: 60
    )

    // Cold-vs-warm agreement crosses different KV states and batch shapes, so
    // scores match to float noise, not bit-exactly. 0.02 in log-prob is far
    // below any token-accounting bug (whole tokens differ by >= O(1)).
    private static let tolerance = 0.02

    // MARK: - Configuration (no model required)

    func testTimeoutDefaultAndEnvParsing() {
        XCTAssertEqual(QwenRanker.defaultTimeoutMilliseconds(environment: [:]), 2_500)
        XCTAssertEqual(
            QwenRanker.defaultTimeoutMilliseconds(environment: ["BILING_MODEL_TIMEOUT_MS": "1200"]),
            1_200
        )
        XCTAssertEqual(
            QwenRanker.defaultTimeoutMilliseconds(environment: ["BILING_MODEL_TIMEOUT_MS": "abc"]),
            2_500
        )
        XCTAssertEqual(
            QwenRanker.defaultTimeoutMilliseconds(environment: ["BILING_MODEL_TIMEOUT_MS": "-5"]),
            2_500
        )
    }

    // MARK: - Load failure (no model required)

    func testCorruptModelFailsToLoadWithoutCrashing() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-corrupt-\(UUID().uuidString).gguf")
        var garbage = Data("NOTAGGUF".utf8)
        garbage.append(Data(repeating: 0x5A, count: 4_096))
        try garbage.write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        XCTAssertThrowsError(try QwenRanker(modelURL: corrupt)) { error in
            guard case RankerError.loadFailed = error else {
                return XCTFail("expected loadFailed, got \(error)")
            }
        }
    }

    func testMissingModelThrowsModelMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/biling-\(UUID().uuidString).gguf")
        XCTAssertThrowsError(try QwenRanker(modelURL: missing)) { error in
            guard case RankerError.modelMissing = error else {
                return XCTFail("expected modelMissing, got \(error)")
            }
        }
    }

    func testManagerDisablesPermanentlyAfterLoadFailure() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-corrupt-\(UUID().uuidString).gguf")
        try Data(repeating: 0x00, count: 1_024).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let manager = RankerManager(modelURL: corrupt, personalModelProvider: { nil })
        XCTAssertThrowsError(try manager.currentRanker())
        XCTAssertEqual(manager.loadAttemptCount, 1)
        XCTAssertTrue(manager.isPermanentlyDisabled)

        // A second request must fail fast without re-reading the file.
        XCTAssertThrowsError(try manager.currentRanker()) { error in
            guard case RankerError.permanentlyDisabled = error else {
                return XCTFail("expected permanentlyDisabled, got \(error)")
            }
        }
        XCTAssertEqual(manager.loadAttemptCount, 1, "a failed load must never be retried")
        XCTAssertTrue(manager.statusLine().hasPrefix("error|"))
    }

    // MARK: - Load failure fallback (model required)

    func testManagerFallsBackFromBrokenPersonalModel() throws {
        let bundled = try requireModelURL()
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-corrupt-personal-\(UUID().uuidString).gguf")
        try Data(repeating: 0x11, count: 2_048).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let manager = RankerManager(modelURL: bundled, personalModelProvider: { corrupt })
        let ranker = try manager.currentRanker()
        XCTAssertFalse(manager.isPermanentlyDisabled)
        XCTAssertEqual(
            manager.loadAttemptCount, 2,
            "expected one failed personal-model attempt and one successful bundled attempt"
        )
        XCTAssertFalse(ranker.modelDescription.isEmpty)
        // The broken personal model must not be retried on a later request.
        _ = try manager.currentRanker()
        XCTAssertEqual(manager.loadAttemptCount, 2)
    }

    // MARK: - Tokenization boundaries and KV reuse (model required)

    func testEmptyContextMatchesSentinelContext() async throws {
        // "Scored alone" (empty context) is defined as scoring after the
        // sentinel "。"; both spellings must price candidates identically.
        let ranker = try requireSharedRanker()
        let candidates = ["天气很好", "天起很好", "电器"]
        let alone = try await scores(ranker, context: "", candidates: candidates)
        let sentinel = try await scores(ranker, context: "。", candidates: candidates)
        for candidate in candidates {
            let lhs = try XCTUnwrap(alone[candidate])
            let rhs = try XCTUnwrap(sentinel[candidate])
            XCTAssertEqual(lhs, rhs, accuracy: Self.tolerance, "candidate \(candidate)")
            XCTAssertTrue(lhs.isFinite)
        }
    }

    func testScoresStableAcrossColdAndWarmCache() async throws {
        // The warm path replays the same query after the KV cache was rolled
        // back for an unrelated context; identical scores mean the merged
        // tokenization, the LCP rollback, and the partial KV copy agree with
        // a from-scratch decode.
        let modelURL = try requireModelURL()
        let context = "我们约好了明天早上"
        let candidates = ["一起去爬山", "一起去派山", "以其去爬山"]

        let cold = try QwenRanker(modelURL: modelURL)
        let coldScores = try await scores(cold, context: context, candidates: candidates)

        let warm = try requireSharedRanker()
        _ = try await scores(warm, context: "完全无关的另一段话，用来扰乱缓存状态。", candidates: ["随便"])
        let warmScores = try await scores(warm, context: context, candidates: candidates)

        for candidate in candidates {
            let lhs = try XCTUnwrap(coldScores[candidate])
            let rhs = try XCTUnwrap(warmScores[candidate])
            XCTAssertTrue(lhs.isFinite, "candidate \(candidate) scored -inf")
            XCTAssertEqual(lhs, rhs, accuracy: Self.tolerance, "candidate \(candidate)")
        }
    }

    func testBoundaryMergingJoinIsStableAndFinite() async throws {
        // ASCII join where BPE merges across the seam: "我说 hel" + "lo world"
        // tokenizes " hello" as one token, so the merged tokenization diverges
        // from the context tokenization before the context ends (the partial
        // KV-copy path). The score must be finite and identical whether the
        // cache is cold or was rolled back from an unrelated context.
        let modelURL = try requireModelURL()
        let context = "我说 hel"
        let candidates = ["lo world", "p me now"]

        let cold = try QwenRanker(modelURL: modelURL)
        let coldScores = try await scores(cold, context: context, candidates: candidates)

        let warm = try requireSharedRanker()
        _ = try await scores(warm, context: "上下文噪声，与本查询无关。", candidates: ["噪声"])
        let warmScores = try await scores(warm, context: context, candidates: candidates)

        for candidate in candidates {
            let lhs = try XCTUnwrap(coldScores[candidate])
            let rhs = try XCTUnwrap(warmScores[candidate])
            XCTAssertTrue(lhs.isFinite, "candidate \(candidate) scored -inf")
            XCTAssertEqual(lhs, rhs, accuracy: Self.tolerance, "candidate \(candidate)")
        }
        // Distinct candidates must not collapse onto one score.
        XCTAssertNotEqual(coldScores[candidates[0]], coldScores[candidates[1]])
    }

    // MARK: - Cancellation (model required)

    func testCancellationReturnsPromptly() async throws {
        let modelURL = try requireModelURL()
        // Fresh instance: the long context must be decoded cold so the cancel
        // lands mid-decode rather than after completion.
        let ranker = try QwenRanker(modelURL: modelURL)
        let clientID = UUID()
        let request = makeRequest(
            clientID: clientID,
            generation: 7,
            context: Self.longContext,
            candidates: ["天气很好", "天启很好", "添七很好"]
        )
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await ranker.rank(request) }
        try await Task.sleep(for: .milliseconds(25))
        ranker.cancel(clientID: clientID, generation: 7)
        do {
            _ = try await task.value
            XCTFail("expected the cancelled request to throw CancellationError")
        } catch is CancellationError {
            // expected
        }
        let elapsed = start.duration(to: clock.now)
        XCTAssertLessThan(
            elapsed, .milliseconds(2_500),
            "cancellation must return well before the scoring timeout"
        )
    }

    func testNewerGenerationSupersedesOlderRequest() async throws {
        let modelURL = try requireModelURL()
        let ranker = try QwenRanker(modelURL: modelURL)
        let clientID = UUID()
        let older = makeRequest(
            clientID: clientID,
            generation: 1,
            context: Self.longContext,
            candidates: ["第一批候选"]
        )
        let newer = makeRequest(
            clientID: clientID,
            generation: 2,
            context: "短上下文",
            candidates: ["第二批", "第二排"]
        )
        let olderTask = Task { try await ranker.rank(older) }
        try await Task.sleep(for: .milliseconds(25))
        // Submitting a newer generation must cancel the in-flight older one
        // without any explicit cancel call.
        let newerReply = try await ranker.rank(newer)
        do {
            _ = try await olderTask.value
            XCTFail("expected the superseded request to throw CancellationError")
        } catch is CancellationError {
            // expected
        }
        let unwrapped = try XCTUnwrap(newerReply)
        XCTAssertEqual(unwrapped.generation, 2)
        XCTAssertEqual(unwrapped.scores.count, 2)
    }

    // MARK: - Timeout (model required)

    func testTimeoutFiresOnAbsurdlyLowBudget() async throws {
        let modelURL = try requireModelURL()
        // 1 ms cannot cover a cold decode of ~1300 context tokens; the
        // deadline must abort the decode and surface as nil, not hang or throw.
        let ranker = try QwenRanker(modelURL: modelURL, timeoutMilliseconds: 1)
        let clock = ContinuousClock()
        let start = clock.now
        let reply = try await ranker.rank(
            makeRequest(context: Self.longContext, candidates: ["天气很好", "天启很好"])
        )
        let elapsed = start.duration(to: clock.now)
        XCTAssertNil(reply, "an expired budget must return nil so the deterministic ranking ships")
        XCTAssertLessThan(
            elapsed, .milliseconds(2_000),
            "the deadline abort must interrupt the decode promptly"
        )
    }

    func testGenerousTimeoutStillScores() async throws {
        let ranker = try requireSharedRanker()
        let reply = try await ranker.rank(
            makeRequest(context: "今天上午", candidates: ["开会", "开慧"])
        )
        let unwrapped = try XCTUnwrap(reply)
        XCTAssertEqual(unwrapped.scores.count, 2)
        XCTAssertTrue(unwrapped.scores.values.allSatisfy(\.isFinite))
    }
}
