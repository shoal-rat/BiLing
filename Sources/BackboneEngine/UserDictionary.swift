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
    func learnedItems() -> [LearnedItem]
    func reset()
}

public final class EncryptedUserDictionary: LearningStore, @unchecked Sendable {
    private let database: OpaquePointer
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "com.biling.user-dictionary")
    private var currentTick: Int = 0

    public init(url: URL, keychainService: String = "com.biling.inputmethod.learning") throws {
        var storageDirectory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? storageDirectory.setResourceValues(resourceValues)
        key = try Self.loadOrCreateKey(service: keychainService)
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
        let schema = """
        CREATE TABLE IF NOT EXISTS learned (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          pinyin_hash BLOB NOT NULL,
          pinyin_cipher BLOB NOT NULL,
          text_cipher BLOB NOT NULL,
          count INTEGER NOT NULL DEFAULT 1,
          tick INTEGER NOT NULL DEFAULT 0,
          skipped REAL NOT NULL DEFAULT 0,
          last_selected REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS learned_unique
          ON learned(pinyin_hash, text_cipher);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.schemaFailed
        }
        currentTick = Self.scalarInt(database, sql: "SELECT COALESCE(MAX(tick), 0) FROM learned;")
    }

    deinit {
        sqlite3_close(database)
    }

    public func candidates(for pinyin: String) -> [Candidate] {
        queue.sync {
            let digest = hash(pinyin)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT id, text_cipher, count, tick, skipped FROM learned WHERE pinyin_hash = ? ORDER BY count DESC LIMIT 50;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            digest.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
            var result: [Candidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let data = Self.columnData(statement, index: 1),
                      let text = decrypt(data) else { continue }
                let count = Int(sqlite3_column_int64(statement, 2))
                let tick = Int(sqlite3_column_int64(statement, 3))
                let skipped = sqlite3_column_double(statement, 4)
                let age = max(0, currentTick - tick)
                let decayed = Double(count) * exp(-Double(age) / 200.0) - skipped * 0.25
                result.append(
                    Candidate(
                        text: text,
                        pinyin: pinyin,
                        source: .learned,
                        consumed: pinyin.count,
                        score: 24 + log1p(max(0, decayed)) * 4
                    )
                )
            }
            return result
        }
    }

    public func record(pinyin: String, chosen: String, shown: [String], chosenIndex: Int) {
        queue.sync {
            currentTick += 1
            let digest = hash(pinyin)
            guard let pinyinCipher = encrypt(pinyin), let textCipher = encrypt(chosen) else { return }
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT id, text_cipher, count FROM learned WHERE pinyin_hash = ?;",
                -1,
                &query,
                nil
            ) == SQLITE_OK, let query else { return }
            digest.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(query, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
            }
            var existingID: Int64?
            var existingCount = 0
            while sqlite3_step(query) == SQLITE_ROW {
                if let encrypted = Self.columnData(query, index: 1), decrypt(encrypted) == chosen {
                    existingID = sqlite3_column_int64(query, 0)
                    existingCount = Int(sqlite3_column_int64(query, 2))
                    break
                }
            }
            sqlite3_finalize(query)

            if let existingID {
                var update: OpaquePointer?
                sqlite3_prepare_v2(
                    database,
                    "UPDATE learned SET count = ?, tick = ?, skipped = MAX(0, skipped - 0.25), last_selected = ? WHERE id = ?;",
                    -1,
                    &update,
                    nil
                )
                sqlite3_bind_int64(update, 1, sqlite3_int64(existingCount + 1))
                sqlite3_bind_int64(update, 2, sqlite3_int64(currentTick))
                sqlite3_bind_double(update, 3, Date().timeIntervalSince1970)
                sqlite3_bind_int64(update, 4, existingID)
                sqlite3_step(update)
                sqlite3_finalize(update)
            } else {
                var insert: OpaquePointer?
                sqlite3_prepare_v2(
                    database,
                    "INSERT INTO learned(pinyin_hash, pinyin_cipher, text_cipher, count, tick, skipped, last_selected) VALUES (?, ?, ?, 1, ?, 0, ?);",
                    -1,
                    &insert,
                    nil
                )
                digest.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(insert, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
                pinyinCipher.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(insert, 2, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
                textCipher.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(insert, 3, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(insert, 4, sqlite3_int64(currentTick))
                sqlite3_bind_double(insert, 5, Date().timeIntervalSince1970)
                sqlite3_step(insert)
                sqlite3_finalize(insert)
            }

            guard chosenIndex > 0 else { return }
            for skippedText in shown.prefix(chosenIndex) {
                var scan: OpaquePointer?
                guard sqlite3_prepare_v2(
                    database,
                    "SELECT id, text_cipher FROM learned WHERE pinyin_hash = ?;",
                    -1,
                    &scan,
                    nil
                ) == SQLITE_OK, let scan else { continue }
                digest.withUnsafeBytes { bytes in
                    _ = sqlite3_bind_blob(scan, 1, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                }
                while sqlite3_step(scan) == SQLITE_ROW {
                    guard let cipher = Self.columnData(scan, index: 1), decrypt(cipher) == skippedText else { continue }
                    let id = sqlite3_column_int64(scan, 0)
                    var penalize: OpaquePointer?
                    sqlite3_prepare_v2(database, "UPDATE learned SET skipped = skipped + 1 WHERE id = ?;", -1, &penalize, nil)
                    sqlite3_bind_int64(penalize, 1, id)
                    sqlite3_step(penalize)
                    sqlite3_finalize(penalize)
                }
                sqlite3_finalize(scan)
            }
        }
    }

    public func learnedItems() -> [LearnedItem] {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT id, pinyin_cipher, text_cipher, count, tick, last_selected FROM learned ORDER BY last_selected DESC;",
                -1,
                &statement,
                nil
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

    public func reset() {
        queue.sync {
            sqlite3_exec(database, "DELETE FROM learned;", nil, nil, nil)
            currentTick = 0
        }
    }

    private func hash(_ text: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key))
    }

    private func encrypt(_ text: String) -> Data? {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key) else { return nil }
        return box.combined
    }

    private func decrypt(_ data: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let clear = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: clear, encoding: .utf8)
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
    private let lock = NSLock()

    public init() {}

    public func candidates(for pinyin: String) -> [Candidate] {
        lock.withLock {
            selections[pinyin, default: [:]].map {
                Candidate(text: $0.key, pinyin: pinyin, source: .learned, consumed: pinyin.count, score: 24 + log1p(Double($0.value)))
            }
        }
    }

    public func record(pinyin: String, chosen: String, shown: [String], chosenIndex: Int) {
        lock.withLock { selections[pinyin, default: [:]][chosen, default: 0] += 1 }
    }

    public func learnedItems() -> [LearnedItem] { [] }
    public func reset() { lock.withLock { selections.removeAll() } }
}
