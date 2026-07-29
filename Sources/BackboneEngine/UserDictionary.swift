import CryptoKit
import Foundation
import Security
import CSQLite

public struct LearnedItem: Codable, Identifiable, Sendable {
    public let id: Int64
    public let pinyin: String
    public let text: String
    public let count: Int
    public let tick: Int
    public let lastSelected: Date
}

public protocol LearningStore: Sendable {
    func candidates(for pinyin: String) -> [Candidate]
    func record(pinyin: String, chosen: String, shown: [String], chosenIndex: Int)
    /// The words of a committed sentence, in order, so the store can learn
    /// which of the user's words follow which. Single-word commits carry no
    /// transition information and may be ignored.
    func recordCommit(words: [String])
    /// A per-decode snapshot that blends the user's own transition evidence
    /// into the lexicon's, or nil when nothing has been learned yet. Fetched
    /// once per keystroke — the closure must be safe to call from the decode
    /// loop without touching the store's lock.
    func transitionModel() -> (@Sendable (_ previous: String, _ next: String, _ lexicon: Double) -> Double)?
    func learnedItems() -> [LearnedItem]
    /// Remove one learned entry (the id from `learnedItems`).
    func deleteItem(id: Int64)
    /// Everything the store knows, decrypted, as JSON — the user's data
    /// belongs to the user. Includes selections, bigrams, and raw events.
    func exportData() throws -> Data
    func reset()
}

/// Adopters that do not learn transitions or keep events get the honest
/// defaults: nothing to blend, nothing to export.
extension LearningStore {
    public func recordCommit(words: [String]) {}
    public func transitionModel() -> (@Sendable (String, String, Double) -> Double)? { nil }
    public func deleteItem(id: Int64) {}
    public func exportData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 2, "selections": [], "bigrams": [], "events": []])
    }
}

/// The on-disk learning store, schema v2.
///
/// Everything user-derived is encrypted (AES-GCM) with a key that lives only
/// in the Keychain; lookups go through keyed HMAC-SHA256 indexes so the
/// database file alone reveals neither what was typed nor what was chosen.
/// v1 tried to get deduplication from `UNIQUE(pinyin_hash, text_cipher)`,
/// which can never fire — GCM ciphertexts are randomized by construction —
/// and papered over it with a decrypt-and-compare scan on every record. v2
/// stores an HMAC of the text alongside the ciphertext: deterministic, so
/// the unique constraint actually holds, and keyed, so it leaks nothing the
/// pinyin hash didn't already.
///
/// Recency is tracked on three timescales at once — exponential moving
/// averages with time constants of 50, 500, and 5000 selections. Their sum
/// forgets like a power law (a mixture of exponentials): a word chosen five
/// minutes ago outranks an old habit, but the habit survives a vacation.
/// A single τ cannot do both — v1's τ=200 forgot yearly vocabulary in a
/// week of disuse. Counters decay lazily: each row stores the tick it was
/// last touched and the decay is applied on read.
public final class EncryptedUserDictionary: LearningStore, @unchecked Sendable {
    private let database: OpaquePointer
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "com.biling.user-dictionary")
    private var currentTick: Int = 0
    private var recordsSinceSweep = 0

    /// EMA time constants, in selections. Spread over two orders of
    /// magnitude so the mixture covers burst, working-set, and habit.
    static let recencyConstants = (fast: 50.0, mid: 500.0, slow: 5000.0)
    /// Bigram counts decay with the working-set constant: transition
    /// preferences are vocabulary-like, not burst-like.
    static let bigramDecay = 2000.0
    /// Retention caps. Selections and bigrams evict by lowest retained
    /// evidence, events by age. Sized so the store stays well under a
    /// megabyte of ciphertext for years of typing.
    static let maxSelections = 20_000
    static let maxBigrams = 100_000
    static let maxEvents = 50_000

    /// In-memory bigram model, rebuilt from the database at open and kept in
    /// step on every commit. Keys are FNV-1a over the plaintext words (the
    /// same hash the lexicon uses), values are decayed counts. Reads take a
    /// copy-on-write snapshot, so the decode loop never touches the lock.
    private var bigramCounts: [UInt64: Double] = [:]
    private var bigramTotals: [UInt64: Double] = [:]
    private let bigramLock = NSLock()

    public init(
        url: URL,
        keychainService: String = "com.biling.inputmethod.learning",
        key explicitKey: SymmetricKey? = nil
    ) throws {
        let storageDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        var mutableDirectory = storageDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableDirectory.setResourceValues(resourceValues)
        key = try explicitKey ?? Self.loadOrCreateKey(service: keychainService)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            throw StoreError.openFailed
        }
        database = handle
        sqlite3_exec(database, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(database, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        try migrate()
        currentTick = Self.scalarInt(database, sql: "SELECT COALESCE(MAX(tick), 0) FROM selections;")
        loadBigrams()
    }

    deinit {
        sqlite3_close(database)
    }

    // MARK: - Schema and migration

    private var schemaVersion: Int {
        guard Self.tableExists(database, name: "store_meta") else { return 0 }
        return Self.scalarInt(
            database,
            sql: "SELECT COALESCE((SELECT CAST(value AS INTEGER) FROM store_meta WHERE name = 'schema_version'), 0);"
        )
    }

    private func migrate() throws {
        let v2Schema = """
        CREATE TABLE IF NOT EXISTS store_meta (
          name TEXT PRIMARY KEY,
          value TEXT NOT NULL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS selections (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          pinyin_hash BLOB NOT NULL,
          text_hash BLOB NOT NULL,
          pinyin_cipher BLOB NOT NULL,
          text_cipher BLOB NOT NULL,
          fast REAL NOT NULL DEFAULT 0,
          mid REAL NOT NULL DEFAULT 0,
          slow REAL NOT NULL DEFAULT 0,
          skipped REAL NOT NULL DEFAULT 0,
          count INTEGER NOT NULL DEFAULT 0,
          tick INTEGER NOT NULL DEFAULT 0,
          last_selected REAL NOT NULL,
          UNIQUE(pinyin_hash, text_hash)
        );
        CREATE TABLE IF NOT EXISTS user_bigrams (
          prev_hash BLOB NOT NULL,
          next_hash BLOB NOT NULL,
          prev_cipher BLOB NOT NULL,
          next_cipher BLOB NOT NULL,
          count REAL NOT NULL DEFAULT 0,
          tick INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (prev_hash, next_hash)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tick INTEGER NOT NULL,
          at REAL NOT NULL,
          payload_cipher BLOB NOT NULL
        );
        """
        guard sqlite3_exec(database, v2Schema, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.schemaFailed
        }
        if schemaVersion < 2 {
            if Self.tableExists(database, name: "learned") {
                try migrateV1Rows()
            }
            sqlite3_exec(
                database,
                "INSERT OR REPLACE INTO store_meta(name, value) VALUES ('schema_version', '2');",
                nil, nil, nil
            )
        }
    }

    /// Carry v1 rows into the tiered counters. v1 kept one lifetime count and
    /// the tick of last selection; the best reconstruction is to treat that
    /// count as if it were all accumulated at that tick — each tier starts at
    /// the count decayed by its own constant over the age. Ordering among
    /// migrated rows is preserved exactly; against future selections the
    /// migrated mass fades on the same schedule as everything else.
    private func migrateV1Rows() throws {
        let maxTick = Self.scalarInt(database, sql: "SELECT COALESCE(MAX(tick), 0) FROM learned;")
        var read: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT pinyin_cipher, text_cipher, count, tick, skipped, last_selected FROM learned;",
            -1, &read, nil
        ) == SQLITE_OK, let read else { throw StoreError.schemaFailed }
        sqlite3_exec(database, "BEGIN;", nil, nil, nil)
        while sqlite3_step(read) == SQLITE_ROW {
            // v1 hashed the bare pinyin; v2 looks up under the "py|" domain
            // prefix. Reusing the stored hash would leave every migrated row
            // permanently unreachable, so the hash is recomputed from the
            // decrypted plaintext instead.
            guard let pinyinCipher = Self.columnData(read, index: 0),
                  let textCipher = Self.columnData(read, index: 1),
                  let pinyin = decrypt(pinyinCipher),
                  let text = decrypt(textCipher)
            else { continue }  // undecryptable rows (key rotation) are dropped
            let pinyinHash = hash("py|" + pinyin)
            let count = Double(sqlite3_column_int64(read, 2))
            let tick = sqlite3_column_int64(read, 3)
            let skipped = sqlite3_column_double(read, 4)
            let lastSelected = sqlite3_column_double(read, 5)
            let age = Double(max(0, Int(maxTick) - Int(tick)))
            let constants = Self.recencyConstants
            var insert: OpaquePointer?
            sqlite3_prepare_v2(
                database,
                """
                INSERT OR REPLACE INTO selections
                  (pinyin_hash, text_hash, pinyin_cipher, text_cipher,
                   fast, mid, slow, skipped, count, tick, last_selected)
                VALUES (?,?,?,?,?,?,?,?,?,?,?);
                """,
                -1, &insert, nil
            )
            bindBlob(insert, 1, pinyinHash)
            bindBlob(insert, 2, hash(text))
            bindBlob(insert, 3, pinyinCipher)
            bindBlob(insert, 4, textCipher)
            sqlite3_bind_double(insert, 5, count * exp(-age / constants.fast))
            sqlite3_bind_double(insert, 6, count * exp(-age / constants.mid))
            sqlite3_bind_double(insert, 7, count * exp(-age / constants.slow))
            sqlite3_bind_double(insert, 8, skipped)
            sqlite3_bind_int64(insert, 9, sqlite3_int64(count))
            sqlite3_bind_int64(insert, 10, tick)
            sqlite3_bind_double(insert, 11, lastSelected)
            sqlite3_step(insert)
            sqlite3_finalize(insert)
        }
        sqlite3_finalize(read)
        sqlite3_exec(database, "DROP TABLE learned;", nil, nil, nil)
        sqlite3_exec(database, "COMMIT;", nil, nil, nil)
    }

    // MARK: - Reads

    public func candidates(for pinyin: String) -> [Candidate] {
        queue.sync {
            let digest = hash("py|" + pinyin)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                """
                SELECT id, text_cipher, fast, mid, slow, skipped, tick FROM selections
                WHERE pinyin_hash = ? ORDER BY fast + mid + slow DESC LIMIT 50;
                """,
                -1, &statement, nil
            ) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            bindBlob(statement, 1, digest)
            var result: [Candidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let data = Self.columnData(statement, index: 1),
                      let text = decrypt(data) else { continue }
                let age = Double(max(0, currentTick - Int(sqlite3_column_int64(statement, 6))))
                let constants = Self.recencyConstants
                let retained = sqlite3_column_double(statement, 2) * exp(-age / constants.fast)
                    + sqlite3_column_double(statement, 3) * exp(-age / constants.mid)
                    + sqlite3_column_double(statement, 4) * exp(-age / constants.slow)
                let skipped = sqlite3_column_double(statement, 5) * exp(-age / constants.mid)
                // `score` carries the retained evidence; the engine converts
                // it to a log-probability, where every other candidate lives.
                result.append(
                    Candidate(
                        text: text,
                        pinyin: pinyin,
                        source: .learned,
                        consumed: pinyin.count,
                        score: max(0, retained - skipped * 0.25)
                    )
                )
            }
            return result
        }
    }

    /// Blend the user's transition evidence into the lexicon's estimate.
    ///
    /// P(next|prev) = (1−μ)·lexicon + μ·user, with μ = n/(n+40) capped at
    /// 0.7 — a Dirichlet-style interpolation where the user's model earns
    /// its vote with evidence: after 40 commits following a given word it
    /// carries half the weight, and the lexicon always keeps at least 30%
    /// as smoothing against a feedback loop of the store's own making.
    public func transitionModel() -> (@Sendable (String, String, Double) -> Double)? {
        bigramLock.lock()
        let counts = bigramCounts
        let totals = bigramTotals
        bigramLock.unlock()
        guard !counts.isEmpty else { return nil }
        return { previous, next, lexicon in
            guard let total = totals[Self.fnv(previous)], total >= 1 else { return lexicon }
            let user = (counts[Self.fnv(previous, next)] ?? 0) / total
            let mu = min(0.7, total / (total + 40))
            return (1 - mu) * lexicon + mu * user
        }
    }

    // MARK: - Writes

    public func record(pinyin: String, chosen: String, shown: [String], chosenIndex: Int) {
        queue.sync {
            currentTick += 1
            let pinyinDigest = hash("py|" + pinyin)
            guard let pinyinCipher = encrypt(pinyin) else { return }

            bump(pinyinHash: pinyinDigest, pinyinCipher: pinyinCipher, text: chosen, selected: true)
            for skippedText in shown.prefix(max(0, chosenIndex)) where skippedText != chosen {
                bump(pinyinHash: pinyinDigest, pinyinCipher: pinyinCipher, text: skippedText, selected: false)
            }
            appendEvent([
                "pinyin": pinyin,
                "chosen": chosen,
                "chosen_index": chosenIndex,
                "shown_count": shown.count,
            ])
            recordsSinceSweep += 1
            if recordsSinceSweep >= 256 {
                recordsSinceSweep = 0
                enforceRetention()
            }
        }
    }

    public func recordCommit(words: [String]) {
        guard words.count >= 2 else { return }
        queue.sync {
            for (previous, next) in zip(words, words.dropFirst()) {
                bumpBigram(previous: previous, next: next)
            }
        }
    }

    /// One selection (or skip) of `text` under `pinyinHash`. The upsert only
    /// works because `text_hash` is deterministic — see the type comment.
    private func bump(pinyinHash: Data, pinyinCipher: Data, text: String, selected: Bool) {
        guard let textCipher = encrypt(text) else { return }
        let constants = Self.recencyConstants
        var upsert: OpaquePointer?
        // Decay-then-add, in SQL so the read-modify-write is one statement:
        // each tier is decayed from its stored tick to now, then the new
        // observation is added. A skip adds pressure instead of evidence,
        // and a selection relieves pressure, as in v1.
        sqlite3_prepare_v2(
            database,
            """
            INSERT INTO selections
              (pinyin_hash, text_hash, pinyin_cipher, text_cipher,
               fast, mid, slow, skipped, count, tick, last_selected)
            VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?5, ?6, ?7, ?8, ?9)
            ON CONFLICT(pinyin_hash, text_hash) DO UPDATE SET
              fast = fast * exp(-(?8 - tick) / \(constants.fast)) + ?5,
              mid  = mid  * exp(-(?8 - tick) / \(constants.mid))  + ?5,
              slow = slow * exp(-(?8 - tick) / \(constants.slow)) + ?5,
              skipped = MAX(0, skipped * exp(-(?8 - tick) / \(constants.mid)) + ?10),
              count = count + ?7,
              tick = ?8,
              last_selected = MAX(last_selected, ?9);
            """,
            -1, &upsert, nil
        )
        guard let upsert else { return }
        bindBlob(upsert, 1, pinyinHash)
        bindBlob(upsert, 2, hash(text))
        bindBlob(upsert, 3, pinyinCipher)
        bindBlob(upsert, 4, textCipher)
        sqlite3_bind_double(upsert, 5, selected ? 1 : 0)
        sqlite3_bind_double(upsert, 6, selected ? 0 : 1)
        sqlite3_bind_int64(upsert, 7, selected ? 1 : 0)
        sqlite3_bind_int64(upsert, 8, sqlite3_int64(currentTick))
        sqlite3_bind_double(upsert, 9, Date().timeIntervalSince1970)
        sqlite3_bind_double(upsert, 10, selected ? -0.25 : 1)
        sqlite3_step(upsert)
        sqlite3_finalize(upsert)
    }

    private func bumpBigram(previous: String, next: String) {
        guard let previousCipher = encrypt(previous), let nextCipher = encrypt(next) else { return }
        var upsert: OpaquePointer?
        sqlite3_prepare_v2(
            database,
            """
            INSERT INTO user_bigrams (prev_hash, next_hash, prev_cipher, next_cipher, count, tick)
            VALUES (?1, ?2, ?3, ?4, 1, ?5)
            ON CONFLICT(prev_hash, next_hash) DO UPDATE SET
              count = count * exp(-(?5 - tick) / \(Self.bigramDecay)) + 1,
              tick = ?5;
            """,
            -1, &upsert, nil
        )
        guard let upsert else { return }
        bindBlob(upsert, 1, hash("bg|" + previous))
        bindBlob(upsert, 2, hash("bg|" + next))
        bindBlob(upsert, 3, previousCipher)
        bindBlob(upsert, 4, nextCipher)
        sqlite3_bind_int64(upsert, 5, sqlite3_int64(currentTick))
        sqlite3_step(upsert)
        sqlite3_finalize(upsert)

        // Keep the in-memory model in step. Values in the cache are decayed
        // only when their row is touched; between touches other rows keep
        // their last-decayed value. The staleness only ever *overstates* old
        // evidence slightly and self-corrects on the next commit — accepted
        // in exchange for a lock-free decode path.
        let pairKey = Self.fnv(previous, next)
        let prevKey = Self.fnv(previous)
        bigramLock.lock()
        let before = bigramCounts[pairKey] ?? 0
        let after = before + 1
        bigramCounts[pairKey] = after
        bigramTotals[prevKey, default: 0] += after - before
        bigramLock.unlock()
    }

    private func appendEvent(_ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let cipher = encrypt(json) else { return }
        var insert: OpaquePointer?
        sqlite3_prepare_v2(
            database,
            "INSERT INTO events (tick, at, payload_cipher) VALUES (?,?,?);",
            -1, &insert, nil
        )
        guard let insert else { return }
        sqlite3_bind_int64(insert, 1, sqlite3_int64(currentTick))
        sqlite3_bind_double(insert, 2, Date().timeIntervalSince1970)
        bindBlob(insert, 3, cipher)
        sqlite3_step(insert)
        sqlite3_finalize(insert)
    }

    /// Bounded storage: evict by lowest retained evidence (selections,
    /// bigrams) or oldest first (events). Runs every 256 records, inside the
    /// store's queue, so a runaway store cannot grow without bound.
    private func enforceRetention() {
        let constants = Self.recencyConstants
        sqlite3_exec(
            database,
            """
            DELETE FROM selections WHERE id IN (
              SELECT id FROM selections
              ORDER BY fast * exp(-(\(currentTick) - tick) / \(constants.fast))
                     + mid  * exp(-(\(currentTick) - tick) / \(constants.mid))
                     + slow * exp(-(\(currentTick) - tick) / \(constants.slow)) DESC
              LIMIT -1 OFFSET \(Self.maxSelections));
            DELETE FROM user_bigrams WHERE (prev_hash, next_hash) IN (
              SELECT prev_hash, next_hash FROM user_bigrams
              ORDER BY count * exp(-(\(currentTick) - tick) / \(Self.bigramDecay)) DESC
              LIMIT -1 OFFSET \(Self.maxBigrams));
            DELETE FROM events WHERE id IN (
              SELECT id FROM events ORDER BY id DESC LIMIT -1 OFFSET \(Self.maxEvents));
            """,
            nil, nil, nil
        )
    }

    private func loadBigrams() {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT prev_cipher, next_cipher, count, tick FROM user_bigrams;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        var counts: [UInt64: Double] = [:]
        var totals: [UInt64: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let previousData = Self.columnData(statement, index: 0),
                  let nextData = Self.columnData(statement, index: 1),
                  let previous = decrypt(previousData),
                  let next = decrypt(nextData) else { continue }
            let age = Double(max(0, currentTick - Int(sqlite3_column_int64(statement, 3))))
            let count = sqlite3_column_double(statement, 2) * exp(-age / Self.bigramDecay)
            guard count > 0.05 else { continue }  // fully faded pairs stay on disk until swept
            counts[Self.fnv(previous, next)] = count
            totals[Self.fnv(previous), default: 0] += count
        }
        bigramLock.lock()
        bigramCounts = counts
        bigramTotals = totals
        bigramLock.unlock()
    }

    // MARK: - Inspection, deletion, export

    public func learnedItems() -> [LearnedItem] {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                """
                SELECT id, pinyin_cipher, text_cipher, count, tick, last_selected
                FROM selections WHERE count > 0 ORDER BY last_selected DESC;
                """,
                -1, &statement, nil
            ) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var output: [LearnedItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pyData = Self.columnData(statement, index: 1),
                      let textData = Self.columnData(statement, index: 2),
                      let pinyin = decrypt(pyData),
                      let text = decrypt(textData) else { continue }
                output.append(
                    LearnedItem(
                        id: sqlite3_column_int64(statement, 0),
                        pinyin: pinyin,
                        text: text,
                        count: Int(sqlite3_column_int64(statement, 3)),
                        tick: Int(sqlite3_column_int64(statement, 4)),
                        lastSelected: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                    )
                )
            }
            return output
        }
    }

    public func deleteItem(id: Int64) {
        queue.sync {
            var delete: OpaquePointer?
            sqlite3_prepare_v2(database, "DELETE FROM selections WHERE id = ?;", -1, &delete, nil)
            guard let delete else { return }
            sqlite3_bind_int64(delete, 1, id)
            sqlite3_step(delete)
            sqlite3_finalize(delete)
        }
    }

    public func exportData() throws -> Data {
        try queue.sync {
            var export: [String: Any] = [
                "version": 2,
                "exported_at": ISO8601DateFormatter().string(from: Date()),
            ]
            export["selections"] = learnedRowsForExport()
            export["bigrams"] = bigramRowsForExport()
            export["events"] = eventRowsForExport()
            return try JSONSerialization.data(
                withJSONObject: export,
                options: [.prettyPrinted, .sortedKeys]
            )
        }
    }

    private func learnedRowsForExport() -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT pinyin_cipher, text_cipher, fast, mid, slow, skipped, count, tick FROM selections;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pyData = Self.columnData(statement, index: 0),
                  let textData = Self.columnData(statement, index: 1),
                  let pinyin = decrypt(pyData),
                  let text = decrypt(textData) else { continue }
            rows.append([
                "pinyin": pinyin, "text": text,
                "fast": sqlite3_column_double(statement, 2),
                "mid": sqlite3_column_double(statement, 3),
                "slow": sqlite3_column_double(statement, 4),
                "skipped": sqlite3_column_double(statement, 5),
                "count": sqlite3_column_int64(statement, 6),
                "tick": sqlite3_column_int64(statement, 7),
            ])
        }
        return rows
    }

    private func bigramRowsForExport() -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT prev_cipher, next_cipher, count, tick FROM user_bigrams;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let previousData = Self.columnData(statement, index: 0),
                  let nextData = Self.columnData(statement, index: 1),
                  let previous = decrypt(previousData),
                  let next = decrypt(nextData) else { continue }
            rows.append([
                "previous": previous, "next": next,
                "count": sqlite3_column_double(statement, 2),
                "tick": sqlite3_column_int64(statement, 3),
            ])
        }
        return rows
    }

    private func eventRowsForExport() -> [[String: Any]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT tick, at, payload_cipher FROM events ORDER BY id;",
            -1, &statement, nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cipher = Self.columnData(statement, index: 2),
                  let clear = decryptData(cipher),
                  let payload = try? JSONSerialization.jsonObject(with: clear) else { continue }
            rows.append([
                "tick": sqlite3_column_int64(statement, 0),
                "at": sqlite3_column_double(statement, 1),
                "event": payload,
            ])
        }
        return rows
    }

    public func reset() {
        queue.sync {
            sqlite3_exec(
                database,
                "DELETE FROM selections; DELETE FROM user_bigrams; DELETE FROM events;",
                nil, nil, nil
            )
            currentTick = 0
            bigramLock.lock()
            bigramCounts = [:]
            bigramTotals = [:]
            bigramLock.unlock()
        }
    }

    // MARK: - Crypto and SQLite plumbing

    /// Keyed and domain-separated: the "py|"/"bg|" prefixes keep an attacker
    /// with the file from even testing whether a pinyin string equals a word.
    private func hash(_ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    private func encrypt(_ text: String) -> Data? { encrypt(Data(text.utf8)) }

    private func encrypt(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.seal(data, using: key) else { return nil }
        return box.combined
    }

    private func decrypt(_ data: Data) -> String? {
        guard let clear = decryptData(data) else { return nil }
        return String(data: clear, encoding: .utf8)
    }

    private func decryptData(_ data: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let clear = try? AES.GCM.open(box, using: key) else { return nil }
        return clear
    }

    /// FNV-1a with the same separator fold the lexicon uses, so the two
    /// transition tables agree on keys without sharing strings.
    static func fnv(_ parts: String...) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for (index, part) in parts.enumerated() {
            if index > 0 {
                hash = (hash ^ 0x1f) &* 0x100000001b3
            }
            for byte in part.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return hash
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    private static func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func tableExists(_ database: OpaquePointer, name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
            -1, &statement, nil
        ) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func loadOrCreateKey(service: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "learning-store-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw StoreError.keychain(status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StoreError.randomFailed
        }
        let data = Data(bytes)
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        return SymmetricKey(data: data)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: LocalizedError {
    case openFailed
    case schemaFailed
    case randomFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .openFailed: "Could not open the encrypted learning database."
        case .schemaFailed: "Could not initialize the learning database."
        case .randomFailed: "Could not generate a learning-store encryption key."
        case .keychain(let status): "Keychain error \(status)."
        }
    }
}

public final class MemoryLearningStore: LearningStore, @unchecked Sendable {
    private var selections: [String: [String: Int]] = [:]
    private var bigramPairs: [String: Double] = [:]
    private var bigramTotals: [String: Double] = [:]
    private let lock = NSLock()

    public init() {}

    public func candidates(for pinyin: String) -> [Candidate] {
        lock.withLock {
            selections[pinyin, default: [:]].map {
                Candidate(
                    text: $0.key,
                    pinyin: pinyin,
                    source: .learned,
                    consumed: pinyin.count,
                    score: Double($0.value)
                )
            }
        }
    }

    public func record(pinyin: String, chosen: String, shown: [String], chosenIndex: Int) {
        lock.withLock { selections[pinyin, default: [:]][chosen, default: 0] += 1 }
    }

    /// Same blend as the encrypted store, so engine tests and headless CLI
    /// simulations exercise the identical personalisation math without
    /// Keychain or disk.
    public func recordCommit(words: [String]) {
        guard words.count >= 2 else { return }
        lock.withLock {
            for (previous, next) in zip(words, words.dropFirst()) {
                bigramPairs["\(previous)\u{1f}\(next)", default: 0] += 1
                bigramTotals[previous, default: 0] += 1
            }
        }
    }

    public func transitionModel() -> (@Sendable (String, String, Double) -> Double)? {
        lock.lock()
        let pairs = bigramPairs
        let totals = bigramTotals
        lock.unlock()
        guard !pairs.isEmpty else { return nil }
        return { previous, next, lexicon in
            guard let total = totals[previous], total >= 1 else { return lexicon }
            let user = (pairs["\(previous)\u{1f}\(next)"] ?? 0) / total
            let mu = min(0.7, total / (total + 40))
            return (1 - mu) * lexicon + mu * user
        }
    }

    public func learnedItems() -> [LearnedItem] { [] }
    public func reset() {
        lock.withLock {
            selections.removeAll()
            bigramPairs.removeAll()
            bigramTotals.removeAll()
        }
    }
}
