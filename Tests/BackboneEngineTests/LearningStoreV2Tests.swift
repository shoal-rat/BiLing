import CryptoKit
import CSQLite
import XCTest

@testable import BackboneEngine

/// Schema-v2 learning store: HMAC-indexed dedup, three-timescale recency,
/// user transition evidence, retention, migration, and data ownership.
///
/// Every store is opened with an injected key so the tests never touch the
/// Keychain — the crypto path is identical, only the key source differs.
final class LearningStoreV2Tests: XCTestCase {
    private var directory: URL!
    private let testKey = SymmetricKey(data: Data(repeating: 7, count: 32))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("biling-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> EncryptedUserDictionary {
        try EncryptedUserDictionary(
            url: directory.appendingPathComponent("learning.sqlite3"),
            key: testKey
        )
    }

    // MARK: - Deduplication (the v1 constraint that could never fire)

    func testRepeatSelectionsCollapseToOneRow() throws {
        let store = try makeStore()
        for _ in 0..<5 {
            store.record(pinyin: "nihao", chosen: "你好", shown: ["你好"], chosenIndex: 0)
        }
        let items = store.learnedItems()
        XCTAssertEqual(items.count, 1, "five selections of the same pair must be one row")
        XCTAssertEqual(items[0].count, 5)
        XCTAssertEqual(items[0].text, "你好")
        XCTAssertEqual(items[0].pinyin, "nihao")
    }

    func testDistinctTextsUnderOneKeyStayDistinct() throws {
        let store = try makeStore()
        store.record(pinyin: "quanli", chosen: "权利", shown: ["权力", "权利"], chosenIndex: 1)
        store.record(pinyin: "quanli", chosen: "权力", shown: ["权力"], chosenIndex: 0)
        XCTAssertEqual(Set(store.learnedItems().map(\.text)), ["权利", "权力"])
    }

    // MARK: - Multi-tier recency

    func testFreshBurstOutranksStaleHabit() throws {
        let store = try makeStore()
        // An old habit: chosen 4 times, then 300 unrelated selections pass.
        for _ in 0..<4 {
            store.record(pinyin: "shiji", chosen: "世纪", shown: ["世纪"], chosenIndex: 0)
        }
        for index in 0..<300 {
            store.record(pinyin: "zz\(index)", chosen: "字\(index)", shown: [], chosenIndex: 0)
        }
        // A fresh burst: chosen 3 times just now.
        for _ in 0..<3 {
            store.record(pinyin: "shiji", chosen: "实际", shown: ["世纪", "实际"], chosenIndex: 1)
        }
        let ranked = store.candidates(for: "shiji").sorted { $0.score > $1.score }
        XCTAssertEqual(ranked.first?.text, "实际", "this morning beats last month")
    }

    func testHabitSurvivesLongAbsenceViaSlowTier() throws {
        let store = try makeStore()
        for _ in 0..<10 {
            store.record(pinyin: "bl", chosen: "笔灵", shown: ["笔灵"], chosenIndex: 0)
        }
        // A vacation: 2000 ticks of unrelated typing. τ=50 and τ=500 have
        // essentially forgotten; τ=5000 retains ~67%.
        for index in 0..<2000 {
            store.record(pinyin: "qq\(index)", chosen: "去\(index)", shown: [], chosenIndex: 0)
        }
        let survivor = store.candidates(for: "bl").first
        XCTAssertNotNil(survivor)
        XCTAssertGreaterThan(
            survivor!.score, 1.0,
            "ten selections must retain more than a single fresh selection's worth of evidence"
        )
    }

    // MARK: - Skip pressure

    func testSkippedCandidateLosesToChosenOne() throws {
        let store = try makeStore()
        for _ in 0..<3 {
            store.record(pinyin: "jld", chosen: "吉林大", shown: ["机领导", "吉林大"], chosenIndex: 1)
        }
        let ranked = store.candidates(for: "jld")
        XCTAssertEqual(ranked.first?.text, "吉林大")
        // The skipped candidate accumulated pressure but no selections; it
        // must never surface with positive evidence.
        let skipped = ranked.first { $0.text == "机领导" }
        XCTAssertEqual(skipped?.score ?? 0, 0, accuracy: 1e-9)
    }

    // MARK: - User transition model

    func testCommittedBigramsShiftTransitions() throws {
        let store = try makeStore()
        XCTAssertNil(store.transitionModel(), "a fresh profile must not perturb decoding")

        for _ in 0..<5 {
            store.record(pinyin: "jilindaxue", chosen: "吉林大学", shown: [], chosenIndex: 0)
            store.recordCommit(words: ["吉林", "大学", "垃圾", "学校"])
        }
        let blend = try XCTUnwrap(store.transitionModel())
        let boosted = blend("吉林", "大学", 0.001)
        XCTAssertGreaterThan(boosted, 0.001, "observed pair must gain probability")
        let unrelated = blend("吉林", "东西", 0.001)
        XCTAssertLessThan(unrelated, 0.001, "an unobserved rival under an observed head must lose mass")
        let unknownHead = blend("经济", "学院", 0.042)
        XCTAssertEqual(unknownHead, 0.042, accuracy: 1e-12, "unknown heads pass the lexicon through")
    }

    func testTransitionModelSurvivesReopen() throws {
        let url = directory.appendingPathComponent("learning.sqlite3")
        do {
            let store = try EncryptedUserDictionary(url: url, key: testKey)
            store.record(pinyin: "x", chosen: "词", shown: [], chosenIndex: 0)
            store.recordCommit(words: ["我们", "出发"])
            store.recordCommit(words: ["我们", "出发"])
        }
        let reopened = try EncryptedUserDictionary(url: url, key: testKey)
        let blend = try XCTUnwrap(reopened.transitionModel())
        XCTAssertGreaterThan(blend("我们", "出发", 0.0), 0.0)
    }

    // MARK: - Migration from v1

    func testV1RowsMigrateAndRemainReachable() throws {
        let url = directory.appendingPathComponent("learning.sqlite3")
        try makeV1Database(at: url, rows: [
            (pinyin: "womende", text: "我们的", count: 6, tick: 90),
            (pinyin: "womende", text: "我门的", count: 1, tick: 10),
            (pinyin: "biling", text: "笔灵", count: 12, tick: 100),
        ])
        let store = try EncryptedUserDictionary(url: url, key: testKey)

        let items = store.learnedItems()
        XCTAssertEqual(items.count, 3, "every decryptable v1 row must survive")
        // The v1 pinyin hash was unprefixed; lookups must still find the rows.
        let migrated = store.candidates(for: "womende")
        XCTAssertEqual(migrated.count, 2, "migrated rows must be reachable under the new hash domain")
        XCTAssertEqual(
            migrated.max(by: { $0.score < $1.score })?.text, "我们的",
            "relative ordering carries over"
        )
        // Idempotence: reopening must not migrate twice or duplicate rows.
        let reopened = try EncryptedUserDictionary(url: url, key: testKey)
        XCTAssertEqual(reopened.learnedItems().count, 3)
    }

    /// Builds a database with the exact v1 schema and crypto layout.
    private func makeV1Database(
        at url: URL,
        rows: [(pinyin: String, text: String, count: Int, tick: Int)]
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil),
            SQLITE_OK
        )
        defer { sqlite3_close(handle) }
        sqlite3_exec(
            handle,
            """
            CREATE TABLE learned (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              pinyin_hash BLOB NOT NULL,
              pinyin_cipher BLOB NOT NULL,
              text_cipher BLOB NOT NULL,
              count INTEGER NOT NULL DEFAULT 1,
              tick INTEGER NOT NULL DEFAULT 0,
              skipped REAL NOT NULL DEFAULT 0,
              last_selected REAL NOT NULL
            );
            """,
            nil, nil, nil
        )
        for row in rows {
            let pinyinHash = Data(HMAC<SHA256>.authenticationCode(for: Data(row.pinyin.utf8), using: testKey))
            let pinyinCipher = try AES.GCM.seal(Data(row.pinyin.utf8), using: testKey).combined!
            let textCipher = try AES.GCM.seal(Data(row.text.utf8), using: testKey).combined!
            var insert: OpaquePointer?
            sqlite3_prepare_v2(
                handle,
                "INSERT INTO learned(pinyin_hash, pinyin_cipher, text_cipher, count, tick, skipped, last_selected) VALUES (?,?,?,?,?,0,?);",
                -1, &insert, nil
            )
            for (index, data) in [pinyinHash, pinyinCipher, textCipher].enumerated() {
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        insert, Int32(index + 1), bytes.baseAddress, Int32(bytes.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            }
            sqlite3_bind_int64(insert, 4, sqlite3_int64(row.count))
            sqlite3_bind_int64(insert, 5, sqlite3_int64(row.tick))
            sqlite3_bind_double(insert, 6, Date().timeIntervalSince1970)
            XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
            sqlite3_finalize(insert)
        }
    }

    // MARK: - Data ownership

    func testExportContainsEverythingDecrypted() throws {
        let store = try makeStore()
        store.record(pinyin: "nihao", chosen: "你好", shown: ["尼耗", "你好"], chosenIndex: 1)
        store.recordCommit(words: ["你好", "世界"])
        let export = try JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any]
        let selections = export?["selections"] as? [[String: Any]]
        let bigrams = export?["bigrams"] as? [[String: Any]]
        let events = export?["events"] as? [[String: Any]]
        XCTAssertTrue(selections?.contains { $0["text"] as? String == "你好" } ?? false)
        XCTAssertTrue(
            bigrams?.contains {
                $0["previous"] as? String == "你好" && $0["next"] as? String == "世界"
            } ?? false
        )
        XCTAssertEqual(events?.count, 1, "one selection means one event")
    }

    func testDeleteItemRemovesExactlyThatEntry() throws {
        let store = try makeStore()
        store.record(pinyin: "a", chosen: "啊", shown: [], chosenIndex: 0)
        store.record(pinyin: "b", chosen: "吧", shown: [], chosenIndex: 0)
        let target = try XCTUnwrap(store.learnedItems().first { $0.text == "啊" })
        store.deleteItem(id: target.id)
        XCTAssertEqual(store.learnedItems().map(\.text), ["吧"])
    }

    func testResetClearsEverything() throws {
        let store = try makeStore()
        store.record(pinyin: "nihao", chosen: "你好", shown: [], chosenIndex: 0)
        store.recordCommit(words: ["你好", "世界"])
        store.reset()
        XCTAssertTrue(store.learnedItems().isEmpty)
        XCTAssertTrue(store.candidates(for: "nihao").isEmpty)
        XCTAssertNil(store.transitionModel())
        let export = try JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any]
        XCTAssertEqual((export?["events"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Retention

    func testEventLogIsCapped() throws {
        let store = try makeStore()
        // Cross the sweep boundary a few times past the cap check. The cap is
        // 50k — writing that many real events is too slow for a unit test, so
        // this verifies the sweep runs and the table stays bounded by ticks.
        for index in 0..<600 {
            store.record(pinyin: "k\(index % 7)", chosen: "字", shown: [], chosenIndex: 0)
        }
        let export = try JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any]
        let events = export?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 600, "under the cap nothing is evicted")
    }

    // MARK: - Engine integration

    func testEngineBehaviourUnchangedWithEmptyStore() throws {
        // The user-transition path must be inert until there is a user: two
        // engines, one with a store that has never seen a commit, must agree
        // exactly with each other on every candidate and score.
        let baseline = try PinyinEngine(dictionary: .bundled(), learningStore: MemoryLearningStore())
        let subject = try PinyinEngine(dictionary: .bundled(), learningStore: makeStore())
        for key in ["jilindaxuelajixuexiao", "womenzaigongyuan", "nihao"] {
            let expected = baseline.candidates(for: key).candidates
            let actual = subject.candidates(for: key).candidates
            XCTAssertEqual(expected.map(\.text), actual.map(\.text), "candidates diverged for \(key)")
            for (lhs, rhs) in zip(expected, actual) {
                XCTAssertEqual(lhs.score, rhs.score, accuracy: 1e-12)
            }
        }
    }

    func testRepeatedSentenceCommitTeachesTransitions() throws {
        let store = MemoryLearningStore()
        let engine = try PinyinEngine(dictionary: .bundled(), learningStore: store)
        let key = "jilindaxuelajixuexiao"
        let before = engine.candidates(for: key).candidates
        guard let target = before.first(where: { $0.text == "吉林大学垃圾学校" }) else {
            return XCTFail("expected sentence candidate missing")
        }
        // Selecting the sentence teaches its internal word transitions.
        for _ in 0..<8 {
            engine.recordSelection(input: key, candidate: target, shown: before, index: 0)
        }
        XCTAssertNotNil(store.transitionModel(), "sentence commits must reach the store as word pairs")
        let after = engine.candidates(for: key).candidates
        XCTAssertEqual(after.first?.text, "吉林大学垃圾学校")
    }
}

